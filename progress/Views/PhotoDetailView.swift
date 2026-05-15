import SwiftUI
import CoreData
import CoreLocation
import MapKit
import Photos
import PhotosUI
import UIKit

struct SnapBackZoomContainer<Content: View>: UIViewRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(rootView: AnyView(content))
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.alwaysBounceHorizontal = false
        scrollView.alwaysBounceVertical = false
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .clear
        scrollView.clipsToBounds = true
        scrollView.contentInsetAdjustmentBehavior = .never

        let hostedView = context.coordinator.hostingController.view!
        hostedView.backgroundColor = .clear
        hostedView.clipsToBounds = true
        hostedView.frame = scrollView.bounds
        hostedView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        scrollView.addSubview(hostedView)
        context.coordinator.updatePanGestureState(for: scrollView)
        return scrollView
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        context.coordinator.hostingController.rootView = AnyView(content)
        context.coordinator.updateHostedViewLayout(in: uiView)
        if uiView.zoomScale < 1.001 {
            context.coordinator.centerContent(in: uiView)
        }
        context.coordinator.updatePanGestureState(for: uiView)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let hostingController: UIHostingController<AnyView>

        init(rootView: AnyView) {
            self.hostingController = UIHostingController(rootView: rootView)
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            hostingController.view
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerContent(in: scrollView)
            updatePanGestureState(for: scrollView)
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            UIView.animate(
                withDuration: 0.28,
                delay: 0,
                usingSpringWithDamping: 0.86,
                initialSpringVelocity: 0.4,
                options: [.curveEaseOut, .allowUserInteraction]
            ) {
                scrollView.zoomScale = 1
                scrollView.contentOffset = .zero
            } completion: { _ in
                self.updateHostedViewLayout(in: scrollView)
                self.centerContent(in: scrollView)
                self.updatePanGestureState(for: scrollView)
            }
        }

        func updateHostedViewLayout(in scrollView: UIScrollView) {
            guard let contentView = hostingController.view else { return }
            let size = scrollView.bounds.size
            contentView.bounds = CGRect(origin: .zero, size: size)
            contentView.center = CGPoint(x: size.width / 2, y: size.height / 2)
            scrollView.contentSize = size
        }

        func centerContent(in scrollView: UIScrollView) {
            guard let contentView = hostingController.view else { return }
            let boundsSize = scrollView.bounds.size
            var frameToCenter = contentView.frame

            frameToCenter.origin.x = frameToCenter.size.width < boundsSize.width
                ? (boundsSize.width - frameToCenter.size.width) / 2
                : 0
            frameToCenter.origin.y = frameToCenter.size.height < boundsSize.height
                ? (boundsSize.height - frameToCenter.size.height) / 2
                : 0

            contentView.frame = frameToCenter
        }

        func updatePanGestureState(for scrollView: UIScrollView) {
            scrollView.panGestureRecognizer.isEnabled = scrollView.zoomScale > 1.01
        }
    }
}

struct LivePhotoContainerView: UIViewRepresentable {
    let imageURL: URL
    let videoURL: URL
    let fallbackImage: UIImage
    var playsHintOnLoad = true

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black

        let fallbackImageView = UIImageView(image: fallbackImage)
        fallbackImageView.contentMode = .scaleAspectFit
        fallbackImageView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(fallbackImageView)

        let livePhotoView = PHLivePhotoView()
        livePhotoView.contentMode = .scaleAspectFit
        livePhotoView.translatesAutoresizingMaskIntoConstraints = false
        livePhotoView.isHidden = true
        container.addSubview(livePhotoView)

        NSLayoutConstraint.activate([
            fallbackImageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            fallbackImageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            fallbackImageView.topAnchor.constraint(equalTo: container.topAnchor),
            fallbackImageView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            livePhotoView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            livePhotoView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            livePhotoView.topAnchor.constraint(equalTo: container.topAnchor),
            livePhotoView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        context.coordinator.livePhotoView = livePhotoView
        context.coordinator.fallbackImageView = fallbackImageView
        livePhotoView.addGestureRecognizer(longPress)

        loadLivePhoto(into: livePhotoView, fallbackImageView: fallbackImageView)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.fallbackImageView?.image = fallbackImage

        if context.coordinator.currentImageURL != imageURL || context.coordinator.currentVideoURL != videoURL {
            context.coordinator.currentImageURL = imageURL
            context.coordinator.currentVideoURL = videoURL
            if let livePhotoView = context.coordinator.livePhotoView,
               let fallbackImageView = context.coordinator.fallbackImageView {
                loadLivePhoto(into: livePhotoView, fallbackImageView: fallbackImageView)
            }
        }
    }

    private func loadLivePhoto(into view: PHLivePhotoView, fallbackImageView: UIImageView) {
        PHLivePhoto.request(
            withResourceFileURLs: [imageURL, videoURL],
            placeholderImage: nil,
            targetSize: .zero,
            contentMode: .aspectFit
        ) { livePhoto, _ in
            DispatchQueue.main.async {
                if let livePhoto {
                    view.livePhoto = livePhoto
                    view.isHidden = false
                    fallbackImageView.isHidden = true
                    if playsHintOnLoad {
                        view.startPlayback(with: .hint)
                    }
                } else {
                    view.livePhoto = nil
                    view.isHidden = true
                    fallbackImageView.isHidden = false
                }
            }
        }
    }

    final class Coordinator: NSObject {
        weak var livePhotoView: PHLivePhotoView?
        weak var fallbackImageView: UIImageView?
        var currentImageURL: URL?
        var currentVideoURL: URL?

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard let view = livePhotoView else { return }

            switch gesture.state {
            case .began:
                view.startPlayback(with: .full)
            case .ended, .cancelled, .failed:
                view.stopPlayback()
            default:
                break
            }
        }
    }
}

struct PhotoDetailItem: Identifiable, Equatable {
    let objectID: NSManagedObjectID
    let fullImageAssetName: String?
    let livePhotoImageAssetName: String?
    let livePhotoVideoAssetName: String?
    let captureDate: Date?
    let locationName: String?
    let latitude: Double
    let longitude: Double
    var isHearted: Bool

    var id: NSManagedObjectID { objectID }

    @MainActor
    init(photo: DailyPhoto) {
        objectID = photo.objectID
        fullImageAssetName = photo.fullImageAssetName
        livePhotoImageAssetName = photo.livePhotoImageAssetName
        livePhotoVideoAssetName = photo.livePhotoVideoAssetName
        captureDate = photo.captureDate
        locationName = photo.locationName
        latitude = photo.latitude
        longitude = photo.longitude
        isHearted = photo.isHearted
    }

    init(gridItem: UIKitPhotoGridItem) {
        objectID = gridItem.objectID
        fullImageAssetName = gridItem.fullImageAssetName
        livePhotoImageAssetName = gridItem.livePhotoImageAssetName
        livePhotoVideoAssetName = gridItem.livePhotoVideoAssetName
        captureDate = gridItem.captureDate
        locationName = gridItem.locationName
        latitude = gridItem.latitude
        longitude = gridItem.longitude
        isHearted = gridItem.isHearted
    }
}

struct PhotoDetailView: View {
    let onClose: (NSManagedObjectID?) -> Void
    let onCurrentItemChanged: (NSManagedObjectID?) -> Void

    @Environment(\.managedObjectContext) private var viewContext

    @State private var detailItems: [PhotoDetailItem]
    @State private var selectedIndex: Int
    @State private var resolvedLocationName = "Unknown location"
    @State private var verticalDismissOffset: CGFloat = 0
    @State private var areControlsVisible = true
    @State private var isShowingShareSheet = false
    @State private var shareSheetURLs: [URL] = []
    @State private var actionError: PhotoDetailActionError?
    @State private var isPerformingAction = false
    @State private var hasSavedCurrentItemToLibrary = false
    @State private var deleteTransition: PhotoDetailDeleteTransition?

    init(
        items: [PhotoDetailItem],
        initialIndex: Int,
        onClose: @escaping (NSManagedObjectID?) -> Void,
        onCurrentItemChanged: @escaping (NSManagedObjectID?) -> Void
    ) {
        self.onClose = onClose
        self.onCurrentItemChanged = onCurrentItemChanged
        _detailItems = State(initialValue: items)
        _selectedIndex = State(initialValue: initialIndex)
    }

    var body: some View {
        ZStack {
            Color.black
                .opacity(backgroundOpacity)
                .ignoresSafeArea()

            PhotoDetailPagingView(
                items: detailItems,
                currentIndex: $selectedIndex,
                deleteTransition: deleteTransition,
                onDeleteTransitionCompleted: completeDeleteTransition
            )
            .ignoresSafeArea(.container, edges: [.top, .bottom])
        }
        .background {
            PhotoDetailBottomToolbarConfigurator(
                isVisible: areControlsVisible,
                locationTitle: resolvedLocationName,
                dateTitle: currentDateText,
                isShareEnabled: !isPerformingAction && currentItem != nil,
                isSaveEnabled: !isPerformingAction && currentItem != nil && !hasSavedCurrentItemToLibrary,
                isDeleteEnabled: !isPerformingAction && currentItem != nil,
                isHeartEnabled: !isPerformingAction && currentItem != nil,
                isHearted: currentItem?.isHearted ?? false,
                saveImageSystemName: saveToLibraryButtonSystemImage,
                onClose: closeCurrentPhoto,
                onShare: shareStillPhoto,
                onSave: saveCurrentAssetToPhotoLibrary,
                onHeart: toggleCurrentPhotoHeart,
                onDelete: deleteCurrentPhoto
            )
        }
        .offset(y: verticalDismissOffset)
        .simultaneousGesture(verticalDismissGesture)
        .animation(.easeInOut(duration: 0.18), value: areControlsVisible)
        .onAppear(perform: clampSelectedIndex)
        .onAppear {
            onCurrentItemChanged(currentItem?.objectID)
        }
        .onChange(of: selectedIndex) { _, _ in
            hasSavedCurrentItemToLibrary = false
            onCurrentItemChanged(currentItem?.objectID)
        }
        .task(id: currentItem?.objectID) {
            await updateLocationName()
        }
        .sheet(isPresented: $isShowingShareSheet) {
            ActivityView(activityItems: shareSheetURLs.map { $0 as Any })
        }
        .alert("Action Failed", isPresented: actionErrorBinding) {
            Button("OK", role: .cancel) {
                actionError = nil
            }
        } message: {
            Text(actionError?.message ?? "Something went wrong.")
        }
    }

    private var currentItem: PhotoDetailItem? {
        guard detailItems.indices.contains(selectedIndex) else { return nil }
        return detailItems[selectedIndex]
    }

    private func clampSelectedIndex() {
        guard !detailItems.isEmpty else { return }
        selectedIndex = min(max(selectedIndex, 0), detailItems.count - 1)
    }

    private var backgroundOpacity: Double {
        let progress = min(max(verticalDismissOffset / 240, 0), 1)
        return 1 - (Double(progress) * 0.22)
    }

    private var verticalDismissGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .onChanged { value in
                let horizontalDistance = abs(value.translation.width)
                let verticalDistance = value.translation.height
                let isPredominantlyVertical = verticalDistance > 0 && abs(verticalDistance) > (horizontalDistance * 1.15)

                guard isPredominantlyVertical else {
                    if verticalDismissOffset != 0 {
                        verticalDismissOffset = 0
                    }
                    return
                }

                verticalDismissOffset = verticalDistance
            }
            .onEnded { value in
                let horizontalDistance = abs(value.translation.width)
                let verticalDistance = value.translation.height
                let predictedVerticalDistance = value.predictedEndTranslation.height
                let isPredominantlyVertical = verticalDistance > 0 && abs(verticalDistance) > (horizontalDistance * 1.15)

                guard isPredominantlyVertical else {
                    resetVerticalDismissOffset()
                    return
                }

                if verticalDistance > 120 || predictedVerticalDistance > 220 {
                    verticalDismissOffset = max(verticalDistance, 160)
                    onClose(currentItem?.objectID)
                } else {
                    resetVerticalDismissOffset()
                }
            }
    }

    private func resetVerticalDismissOffset() {
        guard verticalDismissOffset != 0 else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
            verticalDismissOffset = 0
        }
    }

    private func toggleControlsVisibility() {
        guard !isShowingShareSheet else { return }
        areControlsVisible.toggle()
    }

    private func closeCurrentPhoto() {
        onClose(currentItem?.objectID)
    }

    private var currentDateText: String {
        guard let captureDate = currentItem?.captureDate else { return "Unknown date" }
        return Self.dateTimeFormatter.string(from: captureDate)
    }

    private var saveToLibraryButtonTitle: String {
        if hasSavedCurrentItemToLibrary {
            return "Saved to Library"
        }

        return supportsLivePhoto
            ? "Save Full Live Photo to Library"
            : "Save Photo to Library"
    }

    private var saveToLibraryButtonSystemImage: String {
        hasSavedCurrentItemToLibrary ? "checkmark" : "arrow.down.to.line"
    }

    private var supportsLivePhoto: Bool {
        guard let currentItem else { return false }
        return currentItem.livePhotoImageAssetName != nil && currentItem.livePhotoVideoAssetName != nil
    }

    private var actionErrorBinding: Binding<Bool> {
        Binding(
            get: { actionError != nil },
            set: { newValue in
                if !newValue {
                    actionError = nil
                }
            }
        )
    }

    private func shareStillPhoto() {
        guard !isPerformingAction, let currentItem else { return }

        isPerformingAction = true
        Task { @MainActor in
            defer { isPerformingAction = false }

            do {
                let shareURL = try await PhotoStorageService.shared.prepareStillPhotoShareURL(
                    fullImageAssetName: currentItem.fullImageAssetName ?? currentItem.livePhotoImageAssetName
                )
                shareSheetURLs = [shareURL]
                isShowingShareSheet = true
            } catch {
                actionError = PhotoDetailActionError(message: "Unable to prepare the still photo for sharing.")
            }
        }
    }

    private func saveCurrentAssetToPhotoLibrary() {
        guard !isPerformingAction, let currentItem else { return }

        isPerformingAction = true
        Task { @MainActor in
            defer { isPerformingAction = false }

            do {
                let authorizationStatus = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                guard authorizationStatus == .authorized || authorizationStatus == .limited else {
                    throw PhotoDetailSaveError.photoLibraryAccessDenied
                }

                if let livePhotoImageAssetName = currentItem.livePhotoImageAssetName,
                   let livePhotoVideoAssetName = currentItem.livePhotoVideoAssetName {
                    let resources = try await PhotoStorageService.shared.loadLivePhotoResources(
                        imageAssetName: livePhotoImageAssetName,
                        videoAssetName: livePhotoVideoAssetName
                    )
                    try await saveToPhotoLibrary(
                        imageURL: resources.imageURL,
                        videoURL: resources.videoURL,
                        metadata: currentItem
                    )
                } else {
                    let imageURL = try await PhotoStorageService.shared.prepareStillPhotoShareURL(
                        fullImageAssetName: currentItem.fullImageAssetName ?? currentItem.livePhotoImageAssetName
                    )
                    try await saveToPhotoLibrary(imageURL: imageURL, metadata: currentItem)
                }

                hasSavedCurrentItemToLibrary = true
            } catch let error as PhotoDetailSaveError {
                actionError = PhotoDetailActionError(message: error.localizedDescription)
            } catch {
                actionError = PhotoDetailActionError(message: "Unable to save this photo to the Photos library.")
            }
        }
    }

    private func toggleCurrentPhotoHeart() {
        guard !isPerformingAction, let currentItem else { return }

        do {
            guard let photo = try viewContext.existingObject(with: currentItem.objectID) as? DailyPhoto else {
                throw PhotoDetailHeartError.photoMissing
            }

            let nextValue = !photo.isHearted
            photo.isHearted = nextValue
            photo.modifiedAt = Date()
            try viewContext.save()

            if detailItems.indices.contains(selectedIndex),
               detailItems[selectedIndex].objectID == currentItem.objectID {
                detailItems[selectedIndex].isHearted = nextValue
            }
        } catch {
            viewContext.rollback()
            actionError = PhotoDetailActionError(message: "Unable to update this favorite.")
        }
    }

    private func deleteCurrentPhoto() {
        guard !isPerformingAction, let currentItem else { return }

        let objectID = currentItem.objectID
        let deletedIndex = selectedIndex

        isPerformingAction = true
        Task { @MainActor in
            do {
                try await PhotoStorageService.shared.deletePhoto(objectID, context: viewContext)
                beginDeleteTransition(objectID: objectID, deletedIndex: deletedIndex)
            } catch {
                isPerformingAction = false
                actionError = PhotoDetailActionError(message: "Unable to delete this photo.")
            }
        }
    }

    private func beginDeleteTransition(objectID: NSManagedObjectID, deletedIndex: Int) {
        let remainingItemCount = detailItems.count - 1
        guard remainingItemCount > 0 else {
            isPerformingAction = false
            onClose(nil)
            return
        }

        let targetIndexBeforeRemoval: Int
        let resultIndexAfterRemoval: Int

        if detailItems.indices.contains(deletedIndex + 1) {
            targetIndexBeforeRemoval = deletedIndex + 1
            resultIndexAfterRemoval = deletedIndex
        } else {
            targetIndexBeforeRemoval = max(deletedIndex - 1, 0)
            resultIndexAfterRemoval = targetIndexBeforeRemoval
        }

        deleteTransition = PhotoDetailDeleteTransition(
            deletedObjectID: objectID,
            deletedIndex: deletedIndex,
            targetIndexBeforeRemoval: targetIndexBeforeRemoval,
            resultIndexAfterRemoval: resultIndexAfterRemoval
        )
    }

    private func completeDeleteTransition(_ transition: PhotoDetailDeleteTransition) {
        guard deleteTransition?.id == transition.id else { return }

        detailItems.removeAll { $0.objectID == transition.deletedObjectID }
        deleteTransition = nil
        isPerformingAction = false

        guard !detailItems.isEmpty else {
            onClose(nil)
            return
        }

        let nextIndex = min(transition.resultIndexAfterRemoval, detailItems.count - 1)
        withAnimation(.easeInOut(duration: 0.18)) {
            selectedIndex = nextIndex
            hasSavedCurrentItemToLibrary = false
        }
        onCurrentItemChanged(detailItems[nextIndex].objectID)
    }

    private func saveToPhotoLibrary(
        imageURL: URL,
        videoURL: URL? = nil,
        metadata: PhotoDetailItem
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let creationRequest = PHAssetCreationRequest.forAsset()
                creationRequest.creationDate = metadata.captureDate
                creationRequest.location = photoLocation(for: metadata)
                creationRequest.addResource(with: .photo, fileURL: imageURL, options: nil)

                if let videoURL {
                    creationRequest.addResource(with: .pairedVideo, fileURL: videoURL, options: nil)
                }
            } completionHandler: { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: PhotoDetailSaveError.saveFailed)
                }
            }
        }
    }

    private func photoLocation(for item: PhotoDetailItem) -> CLLocation? {
        guard item.latitude != 0 || item.longitude != 0 else { return nil }
        return CLLocation(latitude: item.latitude, longitude: item.longitude)
    }

    @MainActor
    private func updateLocationName() async {
        guard let currentItem else {
            resolvedLocationName = "Unknown location"
            return
        }

        if let storedLocationName = currentItem.locationName, !storedLocationName.isEmpty {
            resolvedLocationName = storedLocationName
            return
        }

        guard currentItem.latitude != 0 || currentItem.longitude != 0 else {
            resolvedLocationName = "No location"
            return
        }

        if let cachedLocationName = await LocationNameCacheService.shared.cachedName(
            for: currentItem.latitude,
            longitude: currentItem.longitude
        ) {
            resolvedLocationName = cachedLocationName
            return
        }

        let location = CLLocation(latitude: currentItem.latitude, longitude: currentItem.longitude)

        do {
            let resolvedName = try await resolveLocationName(for: location)

            await LocationNameCacheService.shared.setCachedName(
                resolvedName,
                for: currentItem.latitude,
                longitude: currentItem.longitude
            )
            if self.currentItem?.objectID == currentItem.objectID {
                resolvedLocationName = resolvedName
            }
        } catch {
            if self.currentItem?.objectID == currentItem.objectID {
                resolvedLocationName = "Pinned location"
            }
        }
    }

    private func resolveLocationName(for location: CLLocation) async throws -> String {
        guard let request = MKReverseGeocodingRequest(location: location) else {
            return "Pinned location"
        }

        return try await withCheckedThrowingContinuation { continuation in
            request.getMapItems { mapItems, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let resolvedName = mapItems?
                    .compactMap { mapItem in
                        [
                            mapItem.addressRepresentations?.cityWithContext(.short),
                            mapItem.addressRepresentations?.cityName,
                            mapItem.address?.shortAddress,
                            mapItem.name,
                            mapItem.addressRepresentations?.fullAddress(includingRegion: false, singleLine: true)
                        ].compactMap { $0 }
                            .first(where: { !$0.isEmpty })
                    }
                    .first ?? "Pinned location"

                continuation.resume(returning: resolvedName)
            }
        }
    }

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private struct PhotoDetailActionError: Identifiable {
    let id = UUID()
    let message: String
}

private enum PhotoDetailHeartError: Error {
    case photoMissing
}

private struct PhotoDetailBottomToolbarConfigurator: UIViewControllerRepresentable {
    let isVisible: Bool
    let locationTitle: String
    let dateTitle: String
    let isShareEnabled: Bool
    let isSaveEnabled: Bool
    let isDeleteEnabled: Bool
    let isHeartEnabled: Bool
    let isHearted: Bool
    let saveImageSystemName: String
    let onClose: () -> Void
    let onShare: () -> Void
    let onSave: () -> Void
    let onHeart: () -> Void
    let onDelete: () -> Void

    func makeUIViewController(context: Context) -> ToolbarConfigViewController {
        ToolbarConfigViewController()
    }

    func updateUIViewController(_ controller: ToolbarConfigViewController, context: Context) {
        controller.configuration = .init(
            isVisible: isVisible,
            locationTitle: locationTitle,
            dateTitle: dateTitle,
            isShareEnabled: isShareEnabled,
            isSaveEnabled: isSaveEnabled,
            isDeleteEnabled: isDeleteEnabled,
            isHeartEnabled: isHeartEnabled,
            isHearted: isHearted,
            saveImageSystemName: saveImageSystemName,
            onClose: onClose,
            onShare: onShare,
            onSave: onSave,
            onHeart: onHeart,
            onDelete: onDelete
        )
        controller.applyConfigurationIfPossible()
    }

    static func dismantleUIViewController(_ controller: ToolbarConfigViewController, coordinator: ()) {
        controller.clearToolbar()
    }
}

@MainActor
private final class ToolbarConfigViewController: UIViewController {
    struct Configuration: Equatable {
        let isVisible: Bool
        let locationTitle: String
        let dateTitle: String
        let isShareEnabled: Bool
        let isSaveEnabled: Bool
        let isDeleteEnabled: Bool
        let isHeartEnabled: Bool
        let isHearted: Bool
        let saveImageSystemName: String
        var onClose: () -> Void
        var onShare: () -> Void
        var onSave: () -> Void
        var onHeart: () -> Void
        var onDelete: () -> Void

        static func == (lhs: Configuration, rhs: Configuration) -> Bool {
            lhs.isVisible == rhs.isVisible &&
            lhs.locationTitle == rhs.locationTitle &&
            lhs.dateTitle == rhs.dateTitle &&
            lhs.isShareEnabled == rhs.isShareEnabled &&
            lhs.isSaveEnabled == rhs.isSaveEnabled &&
            lhs.isDeleteEnabled == rhs.isDeleteEnabled &&
            lhs.isHeartEnabled == rhs.isHeartEnabled &&
            lhs.isHearted == rhs.isHearted &&
            lhs.saveImageSystemName == rhs.saveImageSystemName
        }
    }

    var configuration: Configuration?
    private var appliedConfiguration: Configuration?
    private weak var configuredViewController: UIViewController?
    private weak var configuredNavigationController: UINavigationController?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        applyConfigurationIfPossible()
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        applyConfigurationIfPossible()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        clearToolbar()
    }

    func applyConfigurationIfPossible() {
        guard let configuration,
              let parentViewController = parent,
              let navigationController = parentViewController.navigationController else { return }

        let chromeViewController = navigationController.topViewController ?? parentViewController

        guard appliedConfiguration != configuration || configuredViewController !== chromeViewController else { return }
        appliedConfiguration = configuration
        configuredViewController = chromeViewController
        configuredNavigationController = navigationController

        chromeViewController.navigationItem.hidesBackButton = true
        chromeViewController.navigationItem.leftItemsSupplementBackButton = false
        chromeViewController.navigationItem.leftBarButtonItem = closeItem()
        chromeViewController.navigationItem.titleView = makeTitleView(configuration: configuration)
        chromeViewController.navigationItem.rightBarButtonItems = []

        applyNavigationAppearance(to: navigationController)

        let share = Self.compactBarButtonItem(
            systemName: "square.and.arrow.up",
            accessibilityLabel: "Share",
            target: self,
            action: #selector(shareTapped)
        )
        share.isEnabled = configuration.isShareEnabled

        let save = Self.compactBarButtonItem(
            systemName: configuration.saveImageSystemName,
            accessibilityLabel: "Save to Library",
            target: self,
            action: #selector(saveTapped)
        )
        save.isEnabled = configuration.isSaveEnabled

        let delete = deleteBarButtonItem()
        delete.tintColor = .systemRed
        delete.isEnabled = configuration.isDeleteEnabled

        let heart = Self.compactBarButtonItem(
            systemName: configuration.isHearted ? "heart.fill" : "heart",
            accessibilityLabel: configuration.isHearted ? "Remove Favorite" : "Favorite",
            target: self,
            action: #selector(heartTapped)
        )
        heart.tintColor = configuration.isHearted ? .systemRed : .white
        heart.isEnabled = configuration.isHeartEnabled

        let items: [UIBarButtonItem] = [
            share,
            save,
            Self.flexibleSpaceItem(),
            heart,
            Self.fixedSpaceItem(width: 44),
            Self.flexibleSpaceItem(),
            delete
        ]

        chromeViewController.setToolbarItems(items, animated: false)
        navigationController.navigationBar.tintColor = .white
        navigationController.toolbar.tintColor = .white
        navigationController.setNavigationBarHidden(false, animated: false)
        navigationController.setToolbarHidden(false, animated: false)
        setChromeVisible(configuration.isVisible, in: navigationController)
    }

    func clearToolbar() {
        guard let configuredViewController,
              let configuredNavigationController else { return }

        appliedConfiguration = nil
        self.configuredViewController = nil
        self.configuredNavigationController = nil
        configuredViewController.navigationItem.leftBarButtonItem = nil
        configuredViewController.navigationItem.titleView = nil
        configuredViewController.navigationItem.rightBarButtonItems = []
        configuredViewController.setToolbarItems([], animated: false)
        configuredNavigationController.navigationBar.alpha = 1
        configuredNavigationController.toolbar.alpha = 1
        configuredNavigationController.navigationBar.isUserInteractionEnabled = true
        configuredNavigationController.toolbar.isUserInteractionEnabled = true
    }

    private func applyNavigationAppearance(to navigationController: UINavigationController) {
        let navigationAppearance = UINavigationBarAppearance()
        navigationAppearance.configureWithDefaultBackground()
        navigationAppearance.backgroundEffect = UIBlurEffect(style: .systemChromeMaterialDark)
        navigationAppearance.backgroundColor = .clear
        navigationAppearance.shadowColor = .clear

        navigationController.navigationBar.standardAppearance = navigationAppearance
        navigationController.navigationBar.compactAppearance = navigationAppearance
        navigationController.navigationBar.scrollEdgeAppearance = navigationAppearance

        let toolbarAppearance = UIToolbarAppearance()
        toolbarAppearance.configureWithDefaultBackground()
        toolbarAppearance.backgroundEffect = UIBlurEffect(style: .systemChromeMaterialDark)
        toolbarAppearance.backgroundColor = .clear
        toolbarAppearance.shadowColor = .clear

        navigationController.toolbar.standardAppearance = toolbarAppearance
        navigationController.toolbar.compactAppearance = toolbarAppearance
        navigationController.toolbar.scrollEdgeAppearance = toolbarAppearance
    }

    private static func flexibleSpaceItem() -> UIBarButtonItem {
        UIBarButtonItem(systemItem: .flexibleSpace)
    }

    private static func fixedSpaceItem(width: CGFloat) -> UIBarButtonItem {
        let item = UIBarButtonItem(systemItem: .fixedSpace)
        item.width = width
        return item
    }

    private func closeItem() -> UIBarButtonItem {
        let image = UIImage(systemName: "chevron.left")?.applyingSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        )
        let item = UIBarButtonItem(
            image: image,
            style: .plain,
            target: self,
            action: #selector(closeTapped)
        )
        item.accessibilityLabel = "Back"
        return item
    }

    private static func compactBarButtonItem(
        systemName: String,
        accessibilityLabel: String,
        target: Any?,
        action: Selector
    ) -> UIBarButtonItem {
        let image = UIImage(systemName: systemName)?.applyingSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        )
        let item = UIBarButtonItem(
            image: image,
            style: .plain,
            target: target,
            action: action
        )
        item.accessibilityLabel = accessibilityLabel
        return item
    }

    private func deleteBarButtonItem() -> UIBarButtonItem {
        let image = UIImage(systemName: "trash")?.applyingSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        )
        let deleteAction = UIAction(
            title: "Delete Photo",
            image: UIImage(systemName: "trash"),
            attributes: .destructive
        ) { [weak self] _ in
            self?.configuration?.onDelete()
        }
        let item = UIBarButtonItem(
            image: image,
            style: .plain,
            target: nil,
            action: nil
        )
        item.accessibilityLabel = "Delete"
        item.menu = UIMenu(title: "Delete photo?", children: [deleteAction])
        return item
    }

    @objc private func closeTapped() {
        configuration?.onClose()
    }

    @objc private func shareTapped() {
        configuration?.onShare()
    }

    @objc private func saveTapped() {
        configuration?.onSave()
    }

    @objc private func heartTapped() {
        configuration?.onHeart()
    }

    private func setChromeVisible(_ isVisible: Bool, in navigationController: UINavigationController) {
        let alpha: CGFloat = isVisible ? 1 : 0
        navigationController.navigationBar.isUserInteractionEnabled = isVisible
        navigationController.toolbar.isUserInteractionEnabled = isVisible

        UIViewPropertyAnimator.runningPropertyAnimator(
            withDuration: 0.18,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseInOut]
        ) {
            navigationController.navigationBar.alpha = alpha
            navigationController.toolbar.alpha = alpha
        }
    }

    private func makeTitleView(configuration: Configuration) -> UIView {
        let titleLabel = UILabel()
        titleLabel.font = .preferredFont(forTextStyle: .subheadline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.text = configuration.locationTitle

        let subtitleLabel = UILabel()
        subtitleLabel.font = .preferredFont(forTextStyle: .caption1)
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.textAlignment = .center
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.text = configuration.dateTitle

        let stackView = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        stackView.axis = .vertical
        stackView.alignment = .center
        stackView.spacing = 1
        stackView.isLayoutMarginsRelativeArrangement = true
        stackView.directionalLayoutMargins = .init(top: 0, leading: 8, bottom: 0, trailing: 8)
        return stackView
    }
}

private enum PhotoDetailSaveError: LocalizedError {
    case photoLibraryAccessDenied
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .photoLibraryAccessDenied:
            "Allow Photos access to save exports to your library."
        case .saveFailed:
            "The photo could not be saved to the Photos library."
        }
    }
}

private struct PhotoDetailPageView: View {
    let item: PhotoDetailItem
    let isCurrentPage: Bool

    private let topChromeClearance: CGFloat = 116
    private static let thumbnailDataProvider = PhotoThumbnailDataProvider()

    @State private var displayedImage: UIImage?
    @State private var hasLoadedFullResolutionImage = false
    @State private var isLoadingLivePhotoResources = false
    @State private var isDownloadingLivePhotoAsset = false
    @State private var livePhotoResources: LivePhotoResources?
    @State private var representedObjectID: NSManagedObjectID?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if isCurrentPage, let livePhotoResources, let displayedImage {
                    SnapBackZoomContainer {
                        LivePhotoContainerView(
                            imageURL: livePhotoResources.imageURL,
                            videoURL: livePhotoResources.videoURL,
                            fallbackImage: displayedImage,
                            playsHintOnLoad: false
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black)
                    }
                } else if let displayedImage {
                    SnapBackZoomContainer {
                        Image(uiImage: displayedImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.black)
                    }
                } else {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            Group {
                if isCurrentPage, shouldShowLivePhotoStatusIndicator {
                    if shouldShowLivePhotoLoadingIndicator {
                        LivePhotoLoadingIndicator(isDownloading: isDownloadingLivePhotoAsset)
                    } else {
                        LivePhotoStatusIndicator(isLivePhoto: hasLivePhoto)
                    }
                }
            }
            .padding(.top, topChromeClearance)
            .padding(.trailing, 16)
        }
        .task(id: PhotoDetailPageTaskKey(objectID: item.objectID, isCurrentPage: isCurrentPage)) {
            await loadImage()
        }
        .onReceive(NotificationCenter.default.publisher(for: CloudKitService.assetTransferDidChangeNotification)) { notification in
            handleAssetTransferNotification(notification)
        }
    }

    @MainActor
    private func loadImage() async {
        let objectID = item.objectID
        if representedObjectID != objectID {
            representedObjectID = objectID
            displayedImage = nil
        }

        hasLoadedFullResolutionImage = false
        livePhotoResources = nil
        isLoadingLivePhotoResources = false
        syncLivePhotoDownloadState()

        if let cachedThumbnail = DecodedThumbnailCache.shared.cachedImage(for: objectID) {
            displayedImage = cachedThumbnail
        } else if displayedImage == nil {
            let thumbnailData = await Self.thumbnailDataProvider.thumbnailData(for: objectID)
            guard !Task.isCancelled, representedObjectID == objectID else { return }

            if let decodedThumbnail = await DecodedThumbnailCache.shared.image(
                for: objectID,
                data: thumbnailData
            ) {
                guard !Task.isCancelled, representedObjectID == objectID else { return }
                displayedImage = decodedThumbnail
            }
        }

        guard let fullImage = try? await PhotoStorageService.shared.loadFullImage(named: item.fullImageAssetName) else {
            return
        }
        guard !Task.isCancelled, representedObjectID == objectID else { return }

        displayedImage = fullImage
        hasLoadedFullResolutionImage = true

        guard isCurrentPage else {
            return
        }

        guard hasLivePhoto else {
            return
        }

        isLoadingLivePhotoResources = true
        defer { isLoadingLivePhotoResources = false }

        guard let resources = try? await PhotoStorageService.shared.loadLivePhotoResources(
            imageAssetName: item.livePhotoImageAssetName,
            videoAssetName: item.livePhotoVideoAssetName
        ) else {
            return
        }
        guard !Task.isCancelled, representedObjectID == objectID else { return }

        livePhotoResources = LivePhotoResources(
            imageURL: resources.imageURL,
            videoURL: resources.videoURL
        )
        syncLivePhotoDownloadState()
    }

    private var hasLivePhoto: Bool {
        item.livePhotoImageAssetName != nil && item.livePhotoVideoAssetName != nil
    }

    private var shouldShowLivePhotoLoadingIndicator: Bool {
        hasLivePhoto &&
        displayedImage != nil &&
        livePhotoResources == nil &&
        (isLoadingLivePhotoResources || isDownloadingLivePhotoAsset)
    }

    private var shouldShowLivePhotoStatusIndicator: Bool {
        hasLoadedFullResolutionImage
    }

    @MainActor
    private func syncLivePhotoDownloadState() {
        let assetNames = [item.livePhotoImageAssetName, item.livePhotoVideoAssetName].compactMap(\.self)
        isDownloadingLivePhotoAsset = CloudSyncMonitor.shared.isDownloading(assetNames: assetNames)
    }

    @MainActor
    private func handleAssetTransferNotification(_ notification: Notification) {
        guard let assetName = notification.userInfo?["assetName"] as? String else {
            return
        }

        let trackedAssetNames = [item.livePhotoImageAssetName, item.livePhotoVideoAssetName].compactMap(\.self)
        guard trackedAssetNames.contains(assetName) else {
            return
        }

        syncLivePhotoDownloadState()
    }
}

private struct PhotoDetailPageTaskKey: Hashable {
    let objectID: NSManagedObjectID
    let isCurrentPage: Bool
}

private struct LivePhotoResources {
    let imageURL: URL
    let videoURL: URL
}

private struct LivePhotoLoadingIndicator: View {
    let isDownloading: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "livephoto")
                .imageScale(.medium)

            ProgressView()
                .controlSize(.small)
                .tint(.white)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.black.opacity(0.55), in: Capsule())
        .overlay(
            Capsule()
                .stroke(.white.opacity(0.14), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isDownloading ? "Live Photo downloading" : "Preparing Live Photo")
    }
}

private struct LivePhotoStatusIndicator: View {
    let isLivePhoto: Bool

    var body: some View {
        Image(systemName: isLivePhoto ? "livephoto" : "livephoto.slash")
            .imageScale(.medium)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(9)
            .background(.black.opacity(0.45), in: Circle())
            .overlay(
                Circle()
                    .stroke(.white.opacity(0.14), lineWidth: 1)
            )
            .accessibilityLabel(isLivePhoto ? "Live Photo" : "Still Photo")
    }
}

private struct PhotoDetailDeleteTransition: Equatable, Identifiable {
    let id = UUID()
    let deletedObjectID: NSManagedObjectID
    let deletedIndex: Int
    let targetIndexBeforeRemoval: Int
    let resultIndexAfterRemoval: Int
}

private struct PhotoDetailPagingView: UIViewControllerRepresentable {
    let items: [PhotoDetailItem]
    @Binding var currentIndex: Int
    let deleteTransition: PhotoDetailDeleteTransition?
    let onDeleteTransitionCompleted: (PhotoDetailDeleteTransition) -> Void

    func makeUIViewController(context: Context) -> PhotoDetailPagingViewController {
        PhotoDetailPagingViewController(
            items: items,
            initialIndex: currentIndex,
            onIndexChanged: { index in
                currentIndex = index
            }
        )
    }

    func updateUIViewController(_ controller: PhotoDetailPagingViewController, context: Context) {
        controller.onIndexChanged = { index in
            currentIndex = index
        }
        controller.onDeleteTransitionCompleted = onDeleteTransitionCompleted

        if let deleteTransition {
            controller.performDeleteTransitionIfNeeded(
                deleteTransition,
                items: items,
                currentIndex: currentIndex
            )
        } else {
            controller.updateItems(items, currentIndex: currentIndex)
        }
    }
}

@MainActor
private final class PhotoDetailPagingViewController: UIViewController {
    var onIndexChanged: (Int) -> Void
    var onDeleteTransitionCompleted: (PhotoDetailDeleteTransition) -> Void = { _ in }

    private let collectionView: UICollectionView
    private var items: [PhotoDetailItem]
    private var currentIndex: Int
    private var didSetInitialOffset = false
    private var activeDeleteTransition: PhotoDetailDeleteTransition?
    private var completedDeleteTransitionID: UUID?
    private var prefetchTasks: [Int: Task<Void, Never>] = [:]

    init(
        items: [PhotoDetailItem],
        initialIndex: Int,
        onIndexChanged: @escaping (Int) -> Void
    ) {
        self.items = items
        self.currentIndex = items.indices.contains(initialIndex) ? initialIndex : 0
        self.onIndexChanged = onIndexChanged

        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)

        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        prefetchTasks.values.forEach { $0.cancel() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.insetsLayoutMarginsFromSafeArea = false
        configureCollectionView()
        schedulePrefetch(around: currentIndex)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateCollectionLayout()

        guard !didSetInitialOffset, collectionView.bounds.width > 0 else { return }
        didSetInitialOffset = true
        scrollToIndex(currentIndex, animated: false)
    }

    func updateItems(_ nextItems: [PhotoDetailItem], currentIndex nextIndex: Int) {
        guard activeDeleteTransition == nil else { return }

        items = nextItems
        currentIndex = items.indices.contains(nextIndex) ? nextIndex : min(currentIndex, max(items.count - 1, 0))

        collectionView.reloadData()
        if didSetInitialOffset {
            scrollToIndex(currentIndex, animated: false)
        }
        schedulePrefetch(around: currentIndex)
        refreshVisibleCells()
    }

    func performDeleteTransitionIfNeeded(
        _ transition: PhotoDetailDeleteTransition,
        items nextItems: [PhotoDetailItem],
        currentIndex nextIndex: Int
    ) {
        guard completedDeleteTransitionID != transition.id else { return }

        if activeDeleteTransition?.id == transition.id {
            return
        }

        if activeDeleteTransition != nil {
            return
        }

        if items != nextItems {
            updateItems(nextItems, currentIndex: nextIndex)
        }

        guard items.indices.contains(transition.deletedIndex),
              items[transition.deletedIndex].objectID == transition.deletedObjectID,
              items.indices.contains(transition.targetIndexBeforeRemoval) else {
            completedDeleteTransitionID = transition.id
            onDeleteTransitionCompleted(transition)
            return
        }

        currentIndex = transition.deletedIndex
        if didSetInitialOffset {
            scrollToIndex(transition.deletedIndex, animated: false)
        }

        activeDeleteTransition = transition
        collectionView.isUserInteractionEnabled = false
        schedulePrefetch(around: transition.targetIndexBeforeRemoval)

        guard didSetInitialOffset, collectionView.bounds.width > 0 else {
            finishActiveDeleteTransition()
            return
        }

        if let cell = collectionView.cellForItem(at: IndexPath(item: transition.deletedIndex, section: 0)) as? PhotoDetailPagingCell {
            cell.animateDeletionFadeToBlack { [weak self] in
                self?.startActiveDeleteTransitionScroll()
            }
        } else {
            startActiveDeleteTransitionScroll()
        }
    }

    private func configureCollectionView() {
        collectionView.backgroundColor = .clear
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.isPagingEnabled = true
        collectionView.decelerationRate = .fast
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.showsVerticalScrollIndicator = false
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.contentInset = .zero
        collectionView.scrollIndicatorInsets = .zero
        collectionView.clipsToBounds = true
        collectionView.register(PhotoDetailPagingCell.self, forCellWithReuseIdentifier: PhotoDetailPagingCell.reuseIdentifier)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)

        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func updateCollectionLayout() {
        collectionView.contentInset = .zero
        collectionView.scrollIndicatorInsets = .zero

        guard let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout else { return }
        let itemSize = collectionView.bounds.size
        guard itemSize.width > 0, itemSize.height > 0, layout.itemSize != itemSize else { return }

        layout.itemSize = itemSize
        layout.invalidateLayout()
        scrollToIndex(currentIndex, animated: false)
    }

    private func scrollToIndex(_ index: Int, animated: Bool) {
        guard items.indices.contains(index), collectionView.bounds.width > 0 else { return }

        collectionView.setContentOffset(
            CGPoint(x: CGFloat(index) * collectionView.bounds.width, y: 0),
            animated: animated
        )
    }

    private func settleToNearestPage(animated: Bool) {
        guard collectionView.bounds.width > 0, !items.isEmpty else { return }

        let rawIndex = collectionView.contentOffset.x / collectionView.bounds.width
        let nearestIndex = min(max(Int(round(rawIndex)), 0), items.count - 1)
        currentIndex = nearestIndex
        onIndexChanged(nearestIndex)
        scrollToIndex(nearestIndex, animated: animated)
        schedulePrefetch(around: nearestIndex)
        refreshVisibleCells()
    }

    private func finishActiveDeleteTransition() {
        guard let transition = activeDeleteTransition else { return }

        activeDeleteTransition = nil
        completedDeleteTransitionID = transition.id
        collectionView.isUserInteractionEnabled = true
        onDeleteTransitionCompleted(transition)
    }

    private func startActiveDeleteTransitionScroll() {
        guard let transition = activeDeleteTransition else { return }
        scrollToIndex(transition.targetIndexBeforeRemoval, animated: true)
    }

    private func schedulePrefetch(around index: Int) {
        let wanted = Set([index - 2, index - 1, index, index + 1, index + 2].filter { items.indices.contains($0) })

        for (taskIndex, task) in prefetchTasks where !wanted.contains(taskIndex) {
            task.cancel()
            prefetchTasks[taskIndex] = nil
        }

        for prefetchIndex in wanted where prefetchTasks[prefetchIndex] == nil {
            let item = items[prefetchIndex]
            prefetchTasks[prefetchIndex] = Task(priority: .utility) { [weak self] in
                await PhotoStorageService.shared.prefetchPagerAssets(
                    fullImageAssetName: item.fullImageAssetName,
                    livePhotoImageAssetName: item.livePhotoImageAssetName,
                    livePhotoVideoAssetName: item.livePhotoVideoAssetName
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.prefetchTasks[prefetchIndex] = nil
                }
            }
        }
    }

    private func refreshVisibleCells() {
        for case let cell as PhotoDetailPagingCell in collectionView.visibleCells {
            guard let indexPath = collectionView.indexPath(for: cell),
                  items.indices.contains(indexPath.item) else {
                continue
            }

            cell.configure(
                with: items[indexPath.item],
                isCurrentPage: indexPath.item == currentIndex,
                parentViewController: self
            )
        }
    }
}

extension PhotoDetailPagingViewController: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UICollectionViewDataSourcePrefetching {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: PhotoDetailPagingCell.reuseIdentifier,
            for: indexPath
        )

        guard let pagingCell = cell as? PhotoDetailPagingCell,
              items.indices.contains(indexPath.item) else {
            return cell
        }

        pagingCell.configure(
            with: items[indexPath.item],
            isCurrentPage: indexPath.item == currentIndex,
            parentViewController: self
        )
        return pagingCell
    }

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths where items.indices.contains(indexPath.item) {
            let item = items[indexPath.item]
            if prefetchTasks[indexPath.item] == nil {
                prefetchTasks[indexPath.item] = Task(priority: .utility) { [weak self] in
                    await PhotoStorageService.shared.prefetchPagerAssets(
                        fullImageAssetName: item.fullImageAssetName,
                        livePhotoImageAssetName: item.livePhotoImageAssetName,
                        livePhotoVideoAssetName: item.livePhotoVideoAssetName
                    )
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        self?.prefetchTasks[indexPath.item] = nil
                    }
                }
            }
        }
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths {
            prefetchTasks[indexPath.item]?.cancel()
            prefetchTasks[indexPath.item] = nil
        }
    }

    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        guard scrollView.bounds.width > 0 else { return }

        let targetIndex = min(
            max(Int(round(targetContentOffset.pointee.x / scrollView.bounds.width)), 0),
            max(items.count - 1, 0)
        )
        targetContentOffset.pointee.x = CGFloat(targetIndex) * scrollView.bounds.width
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        settleToNearestPage(animated: false)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            settleToNearestPage(animated: true)
        }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        if activeDeleteTransition != nil {
            finishActiveDeleteTransition()
            return
        }

        settleToNearestPage(animated: false)
    }
}

@MainActor
private final class PhotoDetailPagingCell: UICollectionViewCell {
    static let reuseIdentifier = "PhotoDetailPagingCell"

    private var representedObjectID: NSManagedObjectID?
    private var isCurrentPage = false
    private weak var parentViewController: UIViewController?
    private var hostingController: UIHostingController<AnyView>?
    private let deletionFadeOverlay = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .clear
        contentView.clipsToBounds = true
        backgroundColor = .clear
        clipsToBounds = true
        configureDeletionFadeOverlay()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        representedObjectID = nil
        isCurrentPage = false
        hostingController?.rootView = AnyView(Color.black)
        deletionFadeOverlay.layer.removeAllAnimations()
        deletionFadeOverlay.alpha = 0
    }

    func configure(
        with item: PhotoDetailItem,
        isCurrentPage: Bool,
        parentViewController: UIViewController
    ) {
        attachHostingControllerIfNeeded(to: parentViewController)

        guard representedObjectID != item.objectID || self.isCurrentPage != isCurrentPage else { return }

        representedObjectID = item.objectID
        self.isCurrentPage = isCurrentPage
        deletionFadeOverlay.layer.removeAllAnimations()
        deletionFadeOverlay.alpha = 0

        hostingController?.rootView = AnyView(
            PhotoDetailPageView(
                item: item,
                isCurrentPage: isCurrentPage
            )
            .id(item.objectID)
            .background(Color.black)
        )
    }

    func animateDeletionFadeToBlack(completion: @escaping () -> Void) {
        deletionFadeOverlay.layer.removeAllAnimations()
        deletionFadeOverlay.alpha = 0
        contentView.bringSubviewToFront(deletionFadeOverlay)

        UIView.animate(
            withDuration: 0.22,
            delay: 0,
            options: [.curveEaseInOut, .beginFromCurrentState]
        ) {
            self.deletionFadeOverlay.alpha = 1
        } completion: { _ in
            completion()
        }
    }

    private func configureDeletionFadeOverlay() {
        deletionFadeOverlay.backgroundColor = .black
        deletionFadeOverlay.alpha = 0
        deletionFadeOverlay.isUserInteractionEnabled = false
        deletionFadeOverlay.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(deletionFadeOverlay)

        NSLayoutConstraint.activate([
            deletionFadeOverlay.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            deletionFadeOverlay.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            deletionFadeOverlay.topAnchor.constraint(equalTo: contentView.topAnchor),
            deletionFadeOverlay.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    private func attachHostingControllerIfNeeded(to parentViewController: UIViewController) {
        if self.parentViewController !== parentViewController {
            detachHostingController()
            self.parentViewController = parentViewController
        }

        guard hostingController == nil else { return }

        let hostingController = UIHostingController(rootView: AnyView(EmptyView()))
        if #available(iOS 16.4, *) {
            hostingController.safeAreaRegions = []
        }
        hostingController.view.backgroundColor = .clear
        hostingController.view.insetsLayoutMarginsFromSafeArea = false
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false

        parentViewController.addChild(hostingController)
        contentView.addSubview(hostingController.view)
        contentView.bringSubviewToFront(deletionFadeOverlay)
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: contentView.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
        hostingController.didMove(toParent: parentViewController)

        self.hostingController = hostingController
    }

    private func detachHostingController() {
        hostingController?.willMove(toParent: nil)
        hostingController?.view.removeFromSuperview()
        hostingController?.removeFromParent()
        hostingController = nil
    }
}
