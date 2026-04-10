import SwiftUI
import CoreData
import Combine

struct PhotoGridView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \DailyPhoto.captureDate, ascending: false)],
        animation: .default)
    private var photos: FetchedResults<DailyPhoto>
    
    @ObservedObject private var notificationNavigation = NotificationNavigationCoordinator.shared

    @State private var showingCamera = false
    @State private var showingNotificationSettings = false
    @State private var showingPhotoPager = false
    @State private var selectedIndex: Int = 0
    @State private var scrollPosition = ScrollPosition(idType: NSManagedObjectID.self)
    @State private var scrollContentOffsetY: CGFloat = 0
    @State private var lastScrollContentOffsetY: CGFloat = 0
    @State private var visibleScrollDate: Date?
    @State private var isScrollDateVisible = false
    @State private var isScrollGestureActive = false
    @State private var firstGridItemFrameInGlobal: CGRect = .zero
    @State private var isSelectionMode = false
    @State private var selectedPhotoIDs: Set<NSManagedObjectID> = []
    @State private var isExporting = false
    @State private var exportedFileURLs: [URL] = []
    @State private var showingExportPicker = false
    @State private var exportAlertMessage: String?
    @State private var showingDeleteConfirmation = false
    @State private var isDeletingSelection = false
    @State private var photoFramesInGridSpace: [NSManagedObjectID: CGRect] = [:]
    @State private var isSelectionSwipeActive = false
    @State private var didResolveSelectionDragIntent = false
    @State private var dragStartLocation: CGPoint = .zero
    @State private var dragCurrentLocation: CGPoint = .zero
    @State private var dragCurrentViewportLocation: CGPoint = .zero
    @State private var autoScrollDirection: SelectionAutoScrollDirection = .none
    @State private var autoScrollIntensityValue: CGFloat = 0
    @State private var scrollViewportSize: CGSize = .zero
    @State private var scrollViewportFrameInGlobal: CGRect = .zero
    @State private var selectionDragStartedOnPhotoID: NSManagedObjectID?
    @State private var selectionSwipeAnchorIndex: Int?
    @State private var selectionSwipeCurrentIndex: Int?
    @State private var selectionSwipeBaseSelection: Set<NSManagedObjectID> = []
    @State private var selectionSwipeOperation: SelectionSwipeOperation = .select
    @State private var lastAutoScrollTickDate: Date?
    @State private var didSyncExifMetadata = false
    private let autoScrollTimer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()
    private let enableScrollDateDebugLogs = false
    
    private let columns = [
        GridItem(.adaptive(minimum: 100, maximum: 150), spacing: 2)
    ]
    
    private var photosArray: [DailyPhoto] {
        Array(photos)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if photos.isEmpty {
                    // Empty state
                    VStack(spacing: 20) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 60))
                            .foregroundStyle(.secondary)
                        
                        Text("No Photos Yet")
                            .font(.title2)
                            .fontWeight(.semibold)
                        
                        Text("Start capturing your daily moments")
                            .font(.body)
                            .foregroundStyle(.secondary)
                        
                        Button(action: { showingCamera = true }) {
                            Label("Take Your First Photo", systemImage: "camera")
                                .font(.headline)
                                .padding()
                                .background(.blue.gradient, in: Capsule())
                                .foregroundStyle(.white)
                        }
                        .accessibilityIdentifier("emptyStateCaptureButton")
                        .padding(.top)
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(photos) { photo in
                                PhotoGridItem(photo: photo)
                                    .overlay(alignment: .topLeading) {
                                        if isSelectionMode {
                                            Image(systemName: selectedPhotoIDs.contains(photo.objectID) ? "checkmark.circle.fill" : "circle")
                                                .font(.title3)
                                                .foregroundStyle(selectedPhotoIDs.contains(photo.objectID) ? .blue : .white.opacity(0.85))
                                                .padding(6)
                                        }
                                    }
                                    .background {
                                        GeometryReader { proxy in
                                            Color.clear
                                                .preference(
                                                    key: PhotoFrameMapPreferenceKey.self,
                                                    value: [photo.objectID: proxy.frame(in: .named("photoGridSpace"))]
                                                )
                                                .preference(
                                                    key: FirstGridItemFramePreferenceKey.self,
                                                    value: photo.objectID == photos.first?.objectID ? proxy.frame(in: .global) : .zero
                                                )
                                        }
                                    }
                                    .id(photo.objectID)
                                    .onTapGesture {
                                        if isSelectionMode {
                                            toggleSelection(for: photo.objectID)
                                        } else if let index = photosArray.firstIndex(where: { $0.objectID == photo.objectID }) {
                                            selectedIndex = index
                                            showingPhotoPager = true
                                        }
                                    }
                            }
                        }
                        .scrollTargetLayout()
                        .padding(.top, 1)
                        .padding(.bottom, 104)
                    }
                    .coordinateSpace(name: "photoGridSpace")
                    .overlay {
                        GeometryReader { proxy in
                            Color.clear
                                .preference(key: GridViewportSizePreferenceKey.self, value: proxy.size)
                                .preference(key: GridViewportFramePreferenceKey.self, value: proxy.frame(in: .global))
                        }
                        .allowsHitTesting(false)
                    }
                    .scrollPosition($scrollPosition)
                    .onScrollGeometryChange(for: ScrollViewportSnapshot.self, of: { geometry in
                        ScrollViewportSnapshot(
                            minY: geometry.contentOffset.y,
                            height: geometry.visibleRect.height
                        )
                    }, action: { _, snapshot in
                        let nextOffset = max(snapshot.minY, 0)
                        let scrollDirection = overlayScrollDirection(from: lastScrollContentOffsetY, to: nextOffset)
                        scrollContentOffsetY = nextOffset
                        lastScrollContentOffsetY = nextOffset
                        if snapshot.height > 0 {
                            scrollViewportSize.height = snapshot.height
                        }
                        if isScrollGestureActive, let date = currentOverlayDate() {
                            showScrollDateOverlay(for: date, direction: scrollDirection)
                        }
                    })
                    .scrollDisabled(isSelectionSwipeActive)
                    .overlay(alignment: .top) {
                        if isScrollDateVisible, let visibleScrollDate {
                            ScrollMonthOverlay(date: visibleScrollDate)
                                .padding(.top, 12)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if !isSelectionMode {
                            floatingCaptureButton
                                .padding(.bottom, 20)
                        }
                    }
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 8, coordinateSpace: .global)
                            .onChanged { value in
                                guard isSelectionMode else { return }
                                handleSelectionDragChanged(value)
                            }
                            .onEnded { _ in
                                guard isSelectionMode else { return }
                                endSelectionSwipe()
                            }
                    )
                    .onScrollPhaseChange { _, newPhase in
                        isScrollGestureActive = newPhase != .idle

                        if newPhase == .idle {
                            withAnimation(.easeOut(duration: 0.2)) {
                                isScrollDateVisible = false
                            }
                        } else if let date = currentOverlayDate() {
                            showScrollDateOverlay(for: date, direction: .none)
                        }
                    }
                    .onPreferenceChange(FirstGridItemFramePreferenceKey.self) { frame in
                        if frame != .zero {
                            firstGridItemFrameInGlobal = frame
                        }
                    }
                    .onPreferenceChange(PhotoFrameMapPreferenceKey.self) { frames in
                        photoFramesInGridSpace = frames
                    }
                    .onPreferenceChange(GridViewportSizePreferenceKey.self) { size in
                        scrollViewportSize = size
                    }
                    .onPreferenceChange(GridViewportFramePreferenceKey.self) { frame in
                        if frame != .zero {
                            scrollViewportFrameInGlobal = frame
                        }
                    }
                    // Auto-scroll intentionally disabled during swipe selection.
                }
            }
            .navigationTitle("Work in Progress")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !photos.isEmpty {
                        Button(isSelectionMode ? "Cancel" : "Select") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isSelectionMode.toggle()
                                endSelectionSwipe()
                                if !isSelectionMode {
                                    selectedPhotoIDs.removeAll()
                                }
                            }
                        }
                    }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    if isSelectionMode {
                        Menu {
                            Button(action: exportSelectedPhotos) {
                                Label("Export Selected (\(selectedPhotoIDs.count))", systemImage: "square.and.arrow.up")
                            }
                            .disabled(selectedPhotoIDs.isEmpty || isExporting)

                            Button(action: exportAllPhotos) {
                                Label("Export All (\(photos.count))", systemImage: "tray.and.arrow.down")
                            }
                            .disabled(photos.isEmpty || isExporting)
                        } label: {
                            if isExporting {
                                ProgressView()
                            } else {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.title3)
                            }
                        }

                        Button(role: .destructive, action: { showingDeleteConfirmation = true }) {
                            if isDeletingSelection {
                                ProgressView()
                            } else {
                                Image(systemName: "trash")
                                    .font(.title3)
                            }
                        }
                        .disabled(selectedPhotoIDs.isEmpty || isDeletingSelection)
                    } else {
                        Button(action: { showingNotificationSettings = true }) {
                            Image(systemName: "gearshape")
                                .font(.title3)
                        }
                    }
                }
            }
            .fullScreenCover(isPresented: $showingCamera) {
                ExperimentalCameraView(
                    gridTargetFrameInGlobal: firstGridItemFrameInGlobal == .zero ? nil : firstGridItemFrameInGlobal
                )
            }
            .sheet(isPresented: $showingPhotoPager) {
                PhotoPagerView(
                    photos: photosArray,
                    selectedIndex: $selectedIndex
                )
            }
            .sheet(isPresented: $showingNotificationSettings) {
                NotificationSettingsView()
            }
            .sheet(isPresented: $showingExportPicker, onDismiss: {
                exportedFileURLs = []
            }) {
                ExportDocumentPicker(urls: exportedFileURLs)
            }
            .alert("Export", isPresented: Binding(
                get: { exportAlertMessage != nil },
                set: { if !$0 { exportAlertMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(exportAlertMessage ?? "")
            }
            .confirmationDialog(
                "Delete selected photos?",
                isPresented: $showingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete \(selectedPhotoIDs.count) Photo\(selectedPhotoIDs.count == 1 ? "" : "s")", role: .destructive) {
                    deleteSelectedPhotos()
                }
                .disabled(selectedPhotoIDs.isEmpty || isDeletingSelection)

                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This action cannot be undone.")
            }
        }
        .onDisappear {
        }
        .onAppear {
            openCameraIfNeededFromNotification()
        }
        .onChange(of: notificationNavigation.cameraOpenRequestToken) { _, token in
            guard token != nil else { return }
            openCameraIfNeededFromNotification()
        }
        .task {
            await syncPhotoMetadataFromExifIfNeeded()
        }
    }

    private func openCameraIfNeededFromNotification() {
        guard notificationNavigation.cameraOpenRequestToken != nil else { return }
        showingCamera = true
        notificationNavigation.consumeCameraOpenRequest()
    }

    private var floatingCaptureButton: some View {
        Button(action: { showingCamera = true }) {
            captureButtonLabel
        }
        .contentShape(.circle)
        .buttonStyle(floatingCaptureButtonStyle)
        .accessibilityLabel("Capture Photo")
        .accessibilityIdentifier("gridCaptureButton")
    }

    @ViewBuilder
    private var captureButtonLabel: some View {
        if #available(iOS 26.0, *) {
            Image(systemName: "camera.fill")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 60, height: 60)
                .background(
                    Circle()
                        .fill(.clear)
                )
                .shadow(color: .black.opacity(0.1), radius: 14, y: 8)
        } else {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)

                Circle()
                    .stroke(Color.white.opacity(0.5), lineWidth: 1)

                Image(systemName: "camera.fill")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .frame(width: 60, height: 60)
            .shadow(color: .black.opacity(0.12), radius: 14, y: 8)
        }
    }

    private var floatingCaptureButtonStyle: some PrimitiveButtonStyle {
        if #available(iOS 26.0, *) {
            return .glass(.regular.interactive())
        } else {
            return .plain
        }
    }

    private func syncPhotoMetadataFromExifIfNeeded() async {
        guard !didSyncExifMetadata else { return }
        guard !photos.isEmpty else { return }
        didSyncExifMetadata = true

        let photosNeedingMetadataSync = photos.filter { photo in
            photo.captureDate == nil || (photo.latitude == 0 && photo.longitude == 0)
        }
        guard !photosNeedingMetadataSync.isEmpty else { return }

        await PhotoStorageService.shared.syncPhotoMetadataFromAssetsIfNeeded(
            photos: photosNeedingMetadataSync,
            context: viewContext
        )
    }

    private func showScrollDateOverlay(for date: Date, direction: OverlayScrollDirection) {
        if let currentDate = visibleScrollDate {
            if isSameMonthAndYear(currentDate, date) {
                return
            }

            let monthComparison = compareMonthYear(date, currentDate)
            if (direction == .down && monthComparison == .orderedDescending) ||
                (direction == .up && monthComparison == .orderedAscending) {
                if enableScrollDateDebugLogs {
                    print("ScrollMonthOverlay ignored transition current=\(debugMonthYear(currentDate)) candidate=\(debugMonthYear(date)) direction=\(direction.rawValue)")
                }
                return
            }
        }

        if enableScrollDateDebugLogs {
            let current = visibleScrollDate.map(debugMonthYear(_:)) ?? "nil"
            print("ScrollMonthOverlay update current=\(current) next=\(debugMonthYear(date)) direction=\(direction.rawValue) offsetY=\(Int(scrollContentOffsetY))")
        }
        visibleScrollDate = date

        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            isScrollDateVisible = true
        }
    }

    private func currentOverlayDate() -> Date? {
        let viewport = CGRect(origin: .zero, size: scrollViewportSize)
        let topVisibleID = photoFramesInGridSpace
            .filter { _, frame in frame.intersects(viewport) }
            .min(by: { lhs, rhs in lhs.value.minY < rhs.value.minY })?
            .key

        if let topVisibleID,
           let positionedPhoto = photos.first(where: { $0.objectID == topVisibleID }),
           let captureDate = positionedPhoto.captureDate {
            return captureDate
        }

        if let visibleScrollDate {
            return visibleScrollDate
        }

        return photos.first?.captureDate
    }

    private func overlayScrollDirection(from previous: CGFloat, to current: CGFloat) -> OverlayScrollDirection {
        let delta = current - previous
        let threshold: CGFloat = 0.4
        if delta > threshold {
            return .down
        }
        if delta < -threshold {
            return .up
        }
        return .none
    }

    private func isSameMonthAndYear(_ lhs: Date, _ rhs: Date) -> Bool {
        Calendar.current.isDate(lhs, equalTo: rhs, toGranularity: .month) &&
            Calendar.current.isDate(lhs, equalTo: rhs, toGranularity: .year)
    }

    private func compareMonthYear(_ lhs: Date, _ rhs: Date) -> ComparisonResult {
        let calendar = Calendar.current
        let lhsComponents = calendar.dateComponents([.year, .month], from: lhs)
        let rhsComponents = calendar.dateComponents([.year, .month], from: rhs)

        if lhsComponents.year == rhsComponents.year {
            let lhsMonth = lhsComponents.month ?? 0
            let rhsMonth = rhsComponents.month ?? 0
            if lhsMonth == rhsMonth { return .orderedSame }
            return lhsMonth < rhsMonth ? .orderedAscending : .orderedDescending
        }

        let lhsYear = lhsComponents.year ?? 0
        let rhsYear = rhsComponents.year ?? 0
        return lhsYear < rhsYear ? .orderedAscending : .orderedDescending
    }

    private func debugMonthYear(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: date)
    }

    private func toggleSelection(for objectID: NSManagedObjectID) {
        if selectedPhotoIDs.contains(objectID) {
            selectedPhotoIDs.remove(objectID)
        } else {
            selectedPhotoIDs.insert(objectID)
        }
    }

    private func exportSelectedPhotos() {
        let selectedPhotos = photos.filter { selectedPhotoIDs.contains($0.objectID) }
        guard !selectedPhotos.isEmpty else {
            exportAlertMessage = "Please select at least one photo to export."
            return
        }
        startExport(for: selectedPhotos)
    }

    private func exportAllPhotos() {
        let allPhotos = Array(photos)
        guard !allPhotos.isEmpty else {
            exportAlertMessage = "No photos available to export."
            return
        }
        startExport(for: allPhotos)
    }

    private func deleteSelectedPhotos() {
        guard !isDeletingSelection else { return }

        let photosToDelete = photos.filter { selectedPhotoIDs.contains($0.objectID) }
        guard !photosToDelete.isEmpty else {
            exportAlertMessage = "Please select at least one photo to delete."
            return
        }

        isDeletingSelection = true

        Task {
            do {
                for photo in photosToDelete {
                    try await PhotoStorageService.shared.deletePhoto(photo, context: viewContext)
                }

                await MainActor.run {
                    isDeletingSelection = false
                    isSelectionMode = false
                    endSelectionSwipe()
                    selectedPhotoIDs.removeAll()
                }
            } catch {
                await MainActor.run {
                    isDeletingSelection = false
                    exportAlertMessage = "Delete failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func startExport(for photosToExport: [DailyPhoto]) {
        guard !isExporting else { return }
        isExporting = true

        Task {
            do {
                let urls = try await PhotoStorageService.shared.prepareExportFiles(for: photosToExport)
                await MainActor.run {
                    exportedFileURLs = urls
                    showingExportPicker = !urls.isEmpty
                    if urls.isEmpty {
                        exportAlertMessage = "Nothing was exported."
                    } else {
                        isSelectionMode = false
                        endSelectionSwipe()
                        selectedPhotoIDs.removeAll()
                    }
                    isExporting = false
                }
            } catch {
                await MainActor.run {
                    exportAlertMessage = "Export failed: \(error.localizedDescription)"
                    isExporting = false
                }
            }
        }
    }

    private func selectRange(at location: CGPoint) {
        guard let hitIndex = nearestPhotoIndex(at: location) else {
            return
        }
        selectRange(to: hitIndex)
    }

    private func selectRange(to hitIndex: Int) {
        guard let anchorIndex = selectionSwipeAnchorIndex,
              photosArray.indices.contains(hitIndex) else {
            return
        }

        selectionSwipeCurrentIndex = hitIndex

        let lower = min(anchorIndex, hitIndex)
        let upper = max(anchorIndex, hitIndex)
        let rangeIDs = Set(photosArray[lower...upper].map(\.objectID))

        var updated = selectionSwipeBaseSelection
        switch selectionSwipeOperation {
        case .select:
            updated.formUnion(rangeIDs)
        case .deselect:
            updated.subtract(rangeIDs)
        }
        selectedPhotoIDs = updated
    }

    private func handleSelectionDragChanged(_ value: DragGesture.Value) {
        let startLocationInGridContent = convertGlobalToGridContentPoint(value.startLocation)
        let currentLocationInGridContent = convertGlobalToGridContentPoint(value.location)
        let currentLocationInViewport = convertGlobalToViewportPoint(value.location)

        if !didResolveSelectionDragIntent {
            didResolveSelectionDragIntent = true
            dragStartLocation = startLocationInGridContent
            selectionDragStartedOnPhotoID = photoID(at: startLocationInGridContent)
            if isSelectionSwipeActive == false {
                lastAutoScrollTickDate = nil
            }
        }

        dragCurrentLocation = currentLocationInGridContent
        dragCurrentViewportLocation = currentLocationInViewport

        let translationX = currentLocationInGridContent.x - startLocationInGridContent.x
        let translationY = currentLocationInGridContent.y - startLocationInGridContent.y
        let horizontalDominant = abs(translationX) > abs(translationY)

        // Only start swipe-select when drag is horizontal and started on a photo.
        if !isSelectionSwipeActive, horizontalDominant, let startedPhotoID = selectionDragStartedOnPhotoID {
            isSelectionSwipeActive = true
            selectionSwipeBaseSelection = selectedPhotoIDs
            if let startIndex = photosArray.firstIndex(where: { $0.objectID == startedPhotoID }) {
                selectionSwipeAnchorIndex = startIndex
                selectionSwipeCurrentIndex = startIndex
                selectionSwipeOperation = selectedPhotoIDs.contains(startedPhotoID) ? .deselect : .select
                selectRange(to: startIndex)
            }
        }

        guard isSelectionSwipeActive else { return }
        selectRange(at: currentLocationInGridContent)
        autoScrollDirection = .none
        autoScrollIntensityValue = 0
    }

    private func endSelectionSwipe() {
        isSelectionSwipeActive = false
        didResolveSelectionDragIntent = false
        autoScrollDirection = .none
        selectionDragStartedOnPhotoID = nil
        selectionSwipeAnchorIndex = nil
        selectionSwipeCurrentIndex = nil
        selectionSwipeBaseSelection = []
        dragCurrentViewportLocation = .zero
        lastAutoScrollTickDate = nil
    }

    private func photoID(at location: CGPoint) -> NSManagedObjectID? {
        photoFramesInGridSpace.first { _, frame in frame.contains(location) }?.key
    }

    private func updateAutoScrollDirection(for location: CGPoint) {
        guard scrollViewportSize.height > 0 else {
            autoScrollDirection = .none
            return
        }

        let edgeThreshold: CGFloat = 92
        if location.y < edgeThreshold {
            autoScrollDirection = .up
        } else if location.y > scrollViewportSize.height - edgeThreshold {
            autoScrollDirection = .down
        } else {
            autoScrollDirection = .none
        }
    }

    private func handleAutoScrollTick(now: Date) {
        _ = now
    }

    private func nearestPhotoIndex(at location: CGPoint) -> Int? {
        if let directHitID = photoFramesInGridSpace.first(where: { _, frame in
            frame.contains(location)
        })?.key {
            return photosArray.firstIndex(where: { $0.objectID == directHitID })
        }

        let nearestID = photoFramesInGridSpace.min(by: { lhs, rhs in
            let lhsCenter = CGPoint(x: lhs.value.midX, y: lhs.value.midY)
            let rhsCenter = CGPoint(x: rhs.value.midX, y: rhs.value.midY)
            let lhsDistance = hypot(lhsCenter.x - location.x, lhsCenter.y - location.y)
            let rhsDistance = hypot(rhsCenter.x - location.x, rhsCenter.y - location.y)
            return lhsDistance < rhsDistance
        })?.key

        guard let nearestID else { return nil }
        return photosArray.firstIndex(where: { $0.objectID == nearestID })
    }

    private func autoScrollIntensity(for location: CGPoint) -> CGFloat {
        guard scrollViewportSize.height > 0 else { return 0 }

        let edgeThreshold: CGFloat = 92
        let y = min(max(location.y, 0), scrollViewportSize.height)
        switch autoScrollDirection {
        case .up:
            let distance = y
            return max(0, min(1, (edgeThreshold - distance) / edgeThreshold))
        case .down:
            let distance = scrollViewportSize.height - y
            return max(0, min(1, (edgeThreshold - distance) / edgeThreshold))
        case .none:
            return 0
        }
    }

    private func convertGlobalToViewportPoint(_ point: CGPoint) -> CGPoint {
        guard scrollViewportFrameInGlobal != .zero else { return point }
        return CGPoint(
            x: point.x - scrollViewportFrameInGlobal.minX,
            y: point.y - scrollViewportFrameInGlobal.minY
        )
    }

    private func convertGlobalToGridContentPoint(_ point: CGPoint) -> CGPoint {
        convertGlobalToViewportPoint(point)
    }

}

struct PhotoGridItem: View {
    @ObservedObject var photo: DailyPhoto
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                if let thumbnailData = photo.thumbnailData,
                   let thumbnail = UIImage(data: thumbnailData) {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.width)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(.gray.opacity(0.3))
                        .frame(width: geometry.size.width, height: geometry.size.width)
                    
                    ProgressView()
                }

                uploadBadge
                    .padding(8)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 0))
        .accessibilityIdentifier("photoGridItem")
    }

    @ViewBuilder
    private var uploadBadge: some View {
        switch photo.uploadState {
        case .pending, .uploading:
            Label("Uploading", systemImage: "icloud.and.arrow.up")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.black.opacity(0.62), in: Capsule())
                .foregroundStyle(.white)
                .accessibilityIdentifier("photoGridUploadBadge")
        case .failed:
            Label("Retrying later", systemImage: "exclamationmark.icloud")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.orange.opacity(0.9), in: Capsule())
                .foregroundStyle(.black)
                .accessibilityIdentifier("photoGridUploadBadge")
        case .uploaded:
            EmptyView()
        }
    }
}

private struct FirstGridItemFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero {
            value = next
        }
    }
}

private struct PhotoFrameMapPreferenceKey: PreferenceKey {
    static var defaultValue: [NSManagedObjectID: CGRect] = [:]

    static func reduce(value: inout [NSManagedObjectID: CGRect], nextValue: () -> [NSManagedObjectID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct GridViewportSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero {
            value = next
        }
    }
}

private struct GridViewportFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero {
            value = next
        }
    }
}

private enum SelectionAutoScrollDirection {
    case up
    case down
    case none

    var label: String {
        switch self {
        case .up:
            return "up"
        case .down:
            return "down"
        case .none:
            return "none"
        }
    }
}

private enum SelectionSwipeOperation {
    case select
    case deselect
}

private enum OverlayScrollDirection: String {
    case up
    case down
    case none
}

private struct ScrollViewportSnapshot: Equatable {
    let minY: CGFloat
    let height: CGFloat
}

private struct DebugSelectionAutoScrollOverlay: View {
    let isSelectionMode: Bool
    let isSelectionSwipeActive: Bool
    let direction: SelectionAutoScrollDirection
    let intensity: CGFloat
    let fingerY: CGFloat
    let viewportHeight: CGFloat
    let contentOffsetY: CGFloat

    var body: some View {
        if isSelectionMode {
            VStack(alignment: .leading, spacing: 4) {
                Text("DEBUG AUTO-SCROLL")
                    .font(.caption2.weight(.semibold))
                Text("swipeActive: \(isSelectionSwipeActive ? "true" : "false")")
                Text("direction: \(direction.label)")
                Text(String(format: "intensity: %.3f", intensity))
                Text(String(format: "fingerY: %.1f", fingerY))
                Text(String(format: "viewportH: %.1f", viewportHeight))
                Text(String(format: "offsetY: %.1f", contentOffsetY))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(.white.opacity(0.25), lineWidth: 1)
            )
            .allowsHitTesting(false)
        }
    }
}

struct ScrollMonthOverlay: View {
    let date: Date
    
    private var month: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "LLLL"
        return formatter.string(from: date)
    }

    private var year: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        return formatter.string(from: date)
    }
    
    var body: some View {
        VStack(spacing: 2) {
            Text(month)
                .font(.headline)
                .fontWeight(.semibold)
            Text(year)
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
    }
}

#Preview {
    PhotoGridView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}
