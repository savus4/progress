import SwiftUI
import UIKit
@preconcurrency import CoreData
import Combine

@MainActor
final class PhotoGridDataController: NSObject, ObservableObject, NSFetchedResultsControllerDelegate {
    @Published private(set) var photoCount = 0
    @Published private(set) var isEmpty = true
    @Published private(set) var changeToken = 0

    private var fetchedResultsController: NSFetchedResultsController<DailyPhoto>?
    private(set) var itemsSnapshot: [UIKitPhotoGridItem] = []

    func configureIfNeeded(context: NSManagedObjectContext) {
        guard fetchedResultsController == nil else { return }

        let request = DailyPhoto.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \DailyPhoto.captureDate, ascending: false)]
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
            itemsSnapshot = []
            photoCount = 0
            isEmpty = true
        }
    }

    var allPhotos: [DailyPhoto] {
        fetchedResultsController?.fetchedObjects ?? []
    }

    func photo(at index: Int) -> DailyPhoto? {
        let photos = allPhotos
        guard photos.indices.contains(index) else { return nil }
        return photos[index]
    }

    func photos(for objectIDs: Set<NSManagedObjectID>) -> [DailyPhoto] {
        allPhotos.filter { objectIDs.contains($0.objectID) }
    }

    func index(of objectID: NSManagedObjectID) -> Int? {
        allPhotos.firstIndex(where: { $0.objectID == objectID })
    }

    func controllerDidChangeContent(_ controller: NSFetchedResultsController<any NSFetchRequestResult>) {
        rebuildSnapshot(from: fetchedResultsController?.fetchedObjects ?? [])
    }

    private func rebuildSnapshot(from photos: [DailyPhoto]) {
        itemsSnapshot = photos.map(UIKitPhotoGridItem.init(photo:))
        photoCount = photos.count
        isEmpty = photos.isEmpty
        changeToken &+= 1
    }
}

struct UIKitPhotoGridItem: Identifiable, Equatable {
    let objectID: NSManagedObjectID
    let captureDate: Date?
    let uploadState: PhotoUploadState
    let assetNames: [String]

    var id: NSManagedObjectID { objectID }

    init(photo: DailyPhoto) {
        objectID = photo.objectID
        captureDate = photo.captureDate
        uploadState = photo.uploadState
        assetNames = [
            photo.fullImageAssetName,
            photo.livePhotoImageAssetName,
            photo.livePhotoVideoAssetName
        ].compactMap { $0 }
    }
}

struct UIKitPhotoGridView: UIViewControllerRepresentable {
    let dataController: PhotoGridDataController
    let changeToken: Int
    let activeDownloadAssetNames: Set<String>
    @Binding var isSelectionMode: Bool
    @Binding var selectedPhotoIDs: Set<NSManagedObjectID>
    let onOpenPhoto: (NSManagedObjectID, Int) -> Void
    let onFirstItemFrameChanged: (CGRect) -> Void
    let onTopVisibleDateChanged: (Date?) -> Void
    let onScrollActivityChanged: (Bool) -> Void

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
            activeDownloadAssetNames: activeDownloadAssetNames,
            isSelectionMode: isSelectionMode,
            selectedPhotoIDs: selectedPhotoIDs
        )
    }

    final class Coordinator: NSObject, PhotoGridCollectionViewControllerDelegate {
        var parent: UIKitPhotoGridView

        init(_ parent: UIKitPhotoGridView) {
            self.parent = parent
        }

        func photoGridController(_ controller: PhotoGridCollectionViewController, didOpenPhotoWith objectID: NSManagedObjectID, at index: Int) {
            parent.onOpenPhoto(objectID, index)
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
    }
}

private enum UIKitPhotoGridSection: Int, Hashable, Sendable {
    case main
}

private final class PhotoGridThumbnailDataProvider {
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
    func photoGridController(_ controller: PhotoGridCollectionViewController, didOpenPhotoWith objectID: NSManagedObjectID, at index: Int)
    func photoGridController(_ controller: PhotoGridCollectionViewController, didUpdateSelection selectedPhotoIDs: Set<NSManagedObjectID>)
    func photoGridController(_ controller: PhotoGridCollectionViewController, didUpdateTopVisibleDate date: Date?)
    func photoGridController(_ controller: PhotoGridCollectionViewController, didUpdateFirstItemFrame frame: CGRect)
    func photoGridController(_ controller: PhotoGridCollectionViewController, didChangeScrollActivity isActive: Bool)
}

@MainActor
final class PhotoGridCollectionViewController: UIViewController {
    weak var delegate: PhotoGridCollectionViewControllerDelegate?

    private let collectionView: UICollectionView
    private var dataSource: UICollectionViewDiffableDataSource<UIKitPhotoGridSection, NSManagedObjectID>!
    private var items: [UIKitPhotoGridItem] = []
    private var itemsByID: [NSManagedObjectID: UIKitPhotoGridItem] = [:]
    private var activeDownloadAssetNames: Set<String> = []
    private var isSelectionMode = false
    private var selectedPhotoIDs: Set<NSManagedObjectID> = []
    private var lastAppliedSelectedPhotoIDs: Set<NSManagedObjectID> = []
    private var selectionPanRecognizer: UIPanGestureRecognizer!
    private var selectionPanAnchorIndexPath: IndexPath?
    private var selectionPanBaseSelection: Set<NSManagedObjectID> = []
    private var selectionPanOperation: SelectionPanOperation = .select
    private var thumbnailTasks: [NSManagedObjectID: Task<Void, Never>] = [:]
    private var currentItemIDs: [NSManagedObjectID] = []
    private var itemIndexByID: [NSManagedObjectID: Int] = [:]
    private var currentChangeToken: Int?
    private var lastReportedTopVisibleMonth: DateComponents?
    private var isScrollMotionActive = false
    private var lastContentOffsetY: CGFloat = 0
    private var preheatDirection: ScrollPreheatDirection = .none
    private var lastTopVisibleReportUptime: TimeInterval = 0
    private var lastVisibleThumbnailKickUptime: TimeInterval = 0
    private let thumbnailDataProvider = PhotoGridThumbnailDataProvider()
    private let maxInflightThumbnailTasks = 48
    private let maxInflightThumbnailTasksDuringScroll = 22
    private let maxNearVisiblePrefetchPerKick = 56
    private let maxCollectionPrefetchPerPass = 24
    private let nearVisiblePreheatWindowMultiplier: CGFloat = 2.0
    private let topVisibleReportInterval: TimeInterval = 0.08
    private let visibleThumbnailKickInterval: TimeInterval = 0.04

    private enum SelectionPanOperation {
        case select
        case deselect
    }

    private enum ScrollPreheatDirection {
        case up
        case down
        case none
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
        activeDownloadAssetNames: Set<String>,
        isSelectionMode: Bool,
        selectedPhotoIDs: Set<NSManagedObjectID>
    ) {
        let didChangeItems = currentChangeToken != changeToken
        let didChangeActiveDownloads = self.activeDownloadAssetNames != activeDownloadAssetNames
        let didChangeSelectionMode = self.isSelectionMode != isSelectionMode

        self.activeDownloadAssetNames = activeDownloadAssetNames
        self.isSelectionMode = isSelectionMode
        self.selectedPhotoIDs = selectedPhotoIDs

        if didChangeItems {
            currentChangeToken = changeToken
            self.items = items
            itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.objectID, $0) })
            itemIndexByID = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element.objectID, $0.offset) })

            let nextItemIDs = items.map(\.objectID)
            if nextItemIDs != currentItemIDs {
                currentItemIDs = nextItemIDs
                lastAppliedSelectedPhotoIDs = []
                applySnapshot()
            }
        }

        synchronizeSelection(animated: false)
        if didChangeItems || didChangeActiveDownloads || didChangeSelectionMode {
            refreshVisibleCells()
        }
        reportTopVisibleDate()
        reportFirstItemFrameIfAvailable()
    }

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<PhotoGridCollectionViewCell, NSManagedObjectID> { [weak self] cell, indexPath, objectID in
            guard let self, indexPath.item < self.items.count, let item = self.itemsByID[objectID] else { return }
            let isDownloading = item.assetNames.contains { self.activeDownloadAssetNames.contains($0) }
            cell.configure(
                with: item,
                isSelectionMode: self.isSelectionMode,
                isSelected: self.selectedPhotoIDs.contains(objectID),
                isDownloading: isDownloading
            )
            self.loadThumbnail(for: item, into: cell)
        }

        dataSource = UICollectionViewDiffableDataSource<UIKitPhotoGridSection, NSManagedObjectID>(
            collectionView: collectionView
        ) { (collectionView: UICollectionView, indexPath: IndexPath, objectID: NSManagedObjectID) in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: objectID)
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<UIKitPhotoGridSection, NSManagedObjectID>()
        snapshot.appendSections([UIKitPhotoGridSection.main])
        snapshot.appendItems(items.map(\.objectID), toSection: UIKitPhotoGridSection.main)
        dataSource.apply(snapshot, animatingDifferences: false)
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
            isSelected: selectedPhotoIDs.contains(item.objectID),
            isDownloading: item.assetNames.contains { activeDownloadAssetNames.contains($0) }
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

        let spacing: CGFloat = 2
        let minWidth: CGFloat = 100
        let maxWidth: CGFloat = 150

        var columns = max(Int((availableWidth + spacing) / (minWidth + spacing)), 1)
        var itemWidth = floor((availableWidth - CGFloat(columns - 1) * spacing) / CGFloat(columns))

        while itemWidth > maxWidth {
            columns += 1
            itemWidth = floor((availableWidth - CGFloat(columns - 1) * spacing) / CGFloat(columns))
        }

        let itemSize = CGSize(width: itemWidth, height: itemWidth)
        if layout.itemSize != itemSize {
            layout.itemSize = itemSize
            layout.invalidateLayout()
        }
    }

    private func loadThumbnail(for item: UIKitPhotoGridItem, into cell: PhotoGridCollectionViewCell) {
        let objectID = item.objectID
        cell.representedObjectID = objectID

        if let cachedImage = DecodedThumbnailCache.shared.cachedImage(for: objectID) {
            cell.setThumbnailImage(cachedImage)
            return
        }

        thumbnailTasks[objectID]?.cancel()
        let maxInflight = isScrollMotionActive ? maxInflightThumbnailTasksDuringScroll : maxInflightThumbnailTasks
        guard thumbnailTasks.count < maxInflight else { return }
        let thumbnailDataProvider = thumbnailDataProvider
        thumbnailTasks[objectID] = Task.detached(priority: .utility) { [weak self, weak cell] in
            guard !Task.isCancelled else {
                await MainActor.run { [weak self] in
                    self?.thumbnailTasks[objectID] = nil
                }
                return
            }

            let data = await thumbnailDataProvider.thumbnailData(for: objectID)
            guard !Task.isCancelled else {
                await MainActor.run { [weak self] in
                    self?.thumbnailTasks[objectID] = nil
                }
                return
            }

            let image = await DecodedThumbnailCache.shared.image(for: objectID, data: data)
            guard !Task.isCancelled else {
                await MainActor.run { [weak self] in
                    self?.thumbnailTasks[objectID] = nil
                }
                return
            }
            await MainActor.run { [weak self, weak cell] in
                if cell?.representedObjectID == objectID {
                    cell?.setThumbnailImage(image)
                }
                self?.thumbnailTasks[objectID] = nil
            }
        }
    }

    private func prefetchThumbnail(for item: UIKitPhotoGridItem) {
        let objectID = item.objectID
        if DecodedThumbnailCache.shared.cachedImage(for: objectID) != nil { return }
        guard thumbnailTasks[objectID] == nil else { return }
        let maxInflight = isScrollMotionActive ? maxInflightThumbnailTasksDuringScroll : maxInflightThumbnailTasks
        guard thumbnailTasks.count < maxInflight else { return }
        let thumbnailDataProvider = thumbnailDataProvider
        thumbnailTasks[objectID] = Task.detached(priority: .utility) { [weak self] in
            guard !Task.isCancelled else {
                await MainActor.run { [weak self] in
                    self?.thumbnailTasks[objectID] = nil
                }
                return
            }

            let data = await thumbnailDataProvider.thumbnailData(for: objectID)
            guard !Task.isCancelled else {
                await MainActor.run { [weak self] in
                    self?.thumbnailTasks[objectID] = nil
                }
                return
            }

            _ = await DecodedThumbnailCache.shared.image(for: objectID, data: data)
            guard !Task.isCancelled else {
                await MainActor.run { [weak self] in
                    self?.thumbnailTasks[objectID] = nil
                }
                return
            }
            await MainActor.run { [weak self] in
                self?.thumbnailTasks[objectID] = nil
            }
        }
    }

    private func cancelThumbnailTask(for objectID: NSManagedObjectID?) {
        guard let objectID else { return }
        thumbnailTasks[objectID]?.cancel()
        thumbnailTasks[objectID] = nil
    }

    private func cancelAllThumbnailTasks() {
        for task in thumbnailTasks.values {
            task.cancel()
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
                    isSelected: true,
                    isDownloading: items[indexPath.item].assetNames.contains { activeDownloadAssetNames.contains($0) }
                )
            }
        } else {
            collectionView.deselectItem(at: indexPath, animated: false)
            delegate?.photoGridController(self, didOpenPhotoWith: objectID, at: indexPath.item)
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
                isSelected: false,
                isDownloading: items[indexPath.item].assetNames.contains { activeDownloadAssetNames.contains($0) }
            )
        }
    }

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths.prefix(maxCollectionPrefetchPerPass) where indexPath.item < items.count {
            prefetchThumbnail(for: items[indexPath.item])
        }
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths where indexPath.item < items.count {
            cancelThumbnailTask(for: items[indexPath.item].objectID)
        }
    }

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard let gridCell = cell as? PhotoGridCollectionViewCell else { return }
        if let representedObjectID = gridCell.representedObjectID {
            cancelThumbnailTask(for: representedObjectID)
            return
        }

        if indexPath.item < items.count {
            cancelThumbnailTask(for: items[indexPath.item].objectID)
        }
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
}

final class PhotoGridCollectionViewCell: UICollectionViewCell {
    var representedObjectID: NSManagedObjectID?
    private let imageView = UIImageView()
    private let placeholderView = UIView()
    private let selectionBadgeImageView = UIImageView()
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
    }

    func configure(
        with item: UIKitPhotoGridItem,
        isSelectionMode: Bool,
        isSelected: Bool,
        isDownloading: Bool
    ) {
        selectionBadgeImageView.isHidden = !isSelectionMode
        if isSelectionMode {
            selectionBadgeImageView.image = UIImage(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            selectionBadgeImageView.tintColor = isSelected ? .systemBlue : UIColor.white.withAlphaComponent(0.85)
        }

        let badge: (text: String, systemName: String, backgroundColor: UIColor, foregroundColor: UIColor)?
        if isDownloading {
            badge = ("Downloading", "arrow.down.circle", UIColor.systemBlue.withAlphaComponent(0.86), .white)
        } else {
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

        statusLabel.font = .preferredFont(forTextStyle: .caption2).bold()
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

            statusLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            statusLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8)
        ])
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
