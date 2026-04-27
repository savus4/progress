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
        scrollView.clipsToBounds = false

        let hostedView = context.coordinator.hostingController.view!
        hostedView.backgroundColor = .clear
        hostedView.frame = scrollView.bounds
        hostedView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        scrollView.addSubview(hostedView)
        context.coordinator.updatePanGestureState(for: scrollView)
        return scrollView
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        context.coordinator.hostingController.rootView = AnyView(content)
        context.coordinator.hostingController.view.frame = uiView.bounds
        if uiView.zoomScale < 1.001 {
            uiView.contentSize = uiView.bounds.size
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
                self.centerContent(in: scrollView)
                self.updatePanGestureState(for: scrollView)
            }
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
    }
}

struct PhotoDetailView: View {
    let items: [PhotoDetailItem]
    let initialIndex: Int
    let onClose: (NSManagedObjectID?) -> Void
    let onCurrentItemChanged: (NSManagedObjectID?) -> Void

    @Environment(\.managedObjectContext) private var viewContext

    @State private var selectedIndex: Int
    @State private var resolvedLocationName = "Unknown location"
    @State private var verticalDismissOffset: CGFloat = 0
    @State private var areControlsVisible = true
    @State private var isShowingShareSheet = false
    @State private var shareSheetURLs: [URL] = []
    @State private var isShowingDeleteConfirmation = false
    @State private var actionError: PhotoDetailActionError?
    @State private var isPerformingAction = false
    @State private var hasSavedCurrentItemToLibrary = false

    init(
        items: [PhotoDetailItem],
        initialIndex: Int,
        onClose: @escaping (NSManagedObjectID?) -> Void,
        onCurrentItemChanged: @escaping (NSManagedObjectID?) -> Void
    ) {
        self.items = items
        self.initialIndex = initialIndex
        self.onClose = onClose
        self.onCurrentItemChanged = onCurrentItemChanged
        _selectedIndex = State(initialValue: initialIndex)
    }

    var body: some View {
        ZStack {
            Color.black
                .opacity(backgroundOpacity)
                .ignoresSafeArea()

            PhotoDetailPagingView(
                items: items,
                currentIndex: $selectedIndex
            )
            .ignoresSafeArea(.container, edges: [.top, .bottom])
        }
        .statusBarHidden()
        .navigationBarBackButtonHidden()
        .toolbarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar, .bottomBar)
        .toolbarColorScheme(.dark, for: .navigationBar, .bottomBar)
        .toolbar(areControlsVisible ? .visible : .hidden, for: .navigationBar, .bottomBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Back", systemImage: "chevron.left", action: closeCurrentPhoto)
            }

            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(resolvedLocationName)
                        .font(.subheadline)
                        .bold()
                        .lineLimit(1)

                    Text(currentDateText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .multilineTextAlignment(.center)
                .accessibilityElement(children: .combine)
            }

            ToolbarItem(placement: .bottomBar) {
                Button("Share", systemImage: "square.and.arrow.up") {
                    shareStillPhoto()
                }
                .disabled(isPerformingAction || currentItem == nil)
            }

            ToolbarItem(placement: .bottomBar) {
                Button(saveToLibraryButtonTitle, systemImage: saveToLibraryButtonSystemImage) {
                    saveCurrentAssetToPhotoLibrary()
                }
                .disabled(isPerformingAction || currentItem == nil || hasSavedCurrentItemToLibrary)
            }

            ToolbarSpacer(.flexible, placement: .bottomBar)

            ToolbarItem(placement: .bottomBar) {
                Button("Delete", systemImage: "trash", role: .destructive) {
                    isShowingDeleteConfirmation = true
                }
                .disabled(isPerformingAction || currentItem == nil)
            }
        }
        .offset(y: verticalDismissOffset)
        .simultaneousGesture(verticalDismissGesture)
        .simultaneousGesture(
            TapGesture().onEnded {
                toggleControlsVisibility()
            }
        )
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
        .alert("Delete Photo?", isPresented: $isShowingDeleteConfirmation, presenting: currentItem) { _ in
            Button("Delete", role: .destructive) {
                deleteCurrentPhoto()
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This removes the photo from your timeline.")
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
        guard items.indices.contains(selectedIndex) else { return nil }
        return items[selectedIndex]
    }

    private func clampSelectedIndex() {
        guard !items.isEmpty else { return }
        selectedIndex = min(max(selectedIndex, 0), items.count - 1)
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

    private func deleteCurrentPhoto() {
        guard !isPerformingAction, let objectID = currentItem?.objectID else { return }

        isPerformingAction = true
        Task { @MainActor in
            defer { isPerformingAction = false }

            do {
                try await PhotoStorageService.shared.deletePhoto(objectID, context: viewContext)
                onClose(nil)
            } catch {
                actionError = PhotoDetailActionError(message: "Unable to delete this photo.")
            }
        }
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
        if #available(iOS 26.0, *),
           let request = MKReverseGeocodingRequest(location: location) {
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
        } else {
            let geocoder = CLGeocoder()
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            return placemarks
                .compactMap { placemark in
                    [
                        placemark.locality,
                        placemark.subLocality,
                        placemark.name
                    ].compactMap { $0 }
                        .first(where: { !$0.isEmpty })
                }
                .first ?? "Pinned location"
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

    private static let thumbnailDataProvider = PhotoThumbnailDataProvider()

    @State private var displayedImage: UIImage?
    @State private var isLoadingFullImage = false
    @State private var isLoadingLivePhotoResources = false
    @State private var isDownloadingLivePhotoAsset = false
    @State private var livePhotoResources: LivePhotoResources?

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

            if shouldShowLivePhotoLoadingIndicator {
                LivePhotoLoadingIndicator(isDownloading: isDownloadingLivePhotoAsset)
                    .padding(.top, 20)
                    .padding(.trailing, 16)
            }
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
        livePhotoResources = nil
        isLoadingLivePhotoResources = false
        syncLivePhotoDownloadState()

        if let cachedThumbnail = DecodedThumbnailCache.shared.cachedImage(for: item.objectID) {
            displayedImage = cachedThumbnail
        } else if displayedImage == nil {
            let thumbnailData = await Self.thumbnailDataProvider.thumbnailData(for: item.objectID)
            guard !Task.isCancelled else { return }

            if let decodedThumbnail = await DecodedThumbnailCache.shared.image(
                for: item.objectID,
                data: thumbnailData
            ) {
                guard !Task.isCancelled else { return }
                displayedImage = decodedThumbnail
            }
        }

        guard !isLoadingFullImage else { return }
        isLoadingFullImage = true
        defer { isLoadingFullImage = false }

        guard let fullImage = try? await PhotoStorageService.shared.loadFullImage(named: item.fullImageAssetName) else {
            return
        }

        displayedImage = fullImage

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
        guard !Task.isCancelled else { return }

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
        isCurrentPage &&
        hasLivePhoto &&
        displayedImage != nil &&
        livePhotoResources == nil &&
        (isLoadingLivePhotoResources || isDownloadingLivePhotoAsset)
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

private struct PhotoDetailPagingView: UIViewControllerRepresentable {
    let items: [PhotoDetailItem]
    @Binding var currentIndex: Int

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
        controller.updateItems(items, currentIndex: currentIndex)
    }
}

@MainActor
private final class PhotoDetailPagingViewController: UIViewController {
    var onIndexChanged: (Int) -> Void

    private let collectionView: UICollectionView
    private var items: [PhotoDetailItem]
    private var currentIndex: Int
    private var didSetInitialOffset = false
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
        items = nextItems
        currentIndex = items.indices.contains(nextIndex) ? nextIndex : min(currentIndex, max(items.count - 1, 0))

        collectionView.reloadData()
        if didSetInitialOffset {
            scrollToIndex(currentIndex, animated: false)
        }
        schedulePrefetch(around: currentIndex)
        refreshVisibleCells()
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
        collectionView.clipsToBounds = false
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
                isCurrentPage: indexPath.item == currentIndex
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
            isCurrentPage: indexPath.item == currentIndex
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
        settleToNearestPage(animated: false)
    }
}

@MainActor
private final class PhotoDetailPagingCell: UICollectionViewCell {
    static let reuseIdentifier = "PhotoDetailPagingCell"

    private var representedObjectID: NSManagedObjectID?
    private var isCurrentPage = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .clear
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        representedObjectID = nil
        isCurrentPage = false
        contentConfiguration = nil
    }

    func configure(with item: PhotoDetailItem, isCurrentPage: Bool) {
        guard representedObjectID != item.objectID || self.isCurrentPage != isCurrentPage else { return }

        representedObjectID = item.objectID
        self.isCurrentPage = isCurrentPage
        contentConfiguration = UIHostingConfiguration {
            PhotoDetailPageView(
                item: item,
                isCurrentPage: isCurrentPage
            )
            .background(Color.black)
        }
        .margins(.all, 0)
    }
}
