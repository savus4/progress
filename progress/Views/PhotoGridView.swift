import SwiftUI
import CoreData
import Combine
import UIKit

private struct PhotoDetailPresentation: Identifiable {
    let items: [PhotoDetailItem]
    let initialIndex: Int

    var id: NSManagedObjectID {
        guard items.indices.contains(initialIndex) else {
            return items[0].objectID
        }
        return items[initialIndex].objectID
    }
}

private struct PortraitVideoExportPresentation: Identifiable {
    let id = UUID()
    let photos: [PortraitVideoExportItem]
}

struct PhotoGridView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @ObservedObject private var notificationNavigation = NotificationNavigationCoordinator.shared
    @StateObject private var dataController = PhotoGridDataController()
    @StateObject private var cloudSyncMonitor = CloudSyncMonitor.shared
    @StateObject private var photoImporter = PhotoImportCoordinator.shared

    @State private var showingCamera = false
    @State private var showingNotificationSettings = false
    @State private var photoDetailPresentation: PhotoDetailPresentation?
    @State private var activePhotoDetailObjectID: NSManagedObjectID?
    @State private var pendingDetailDismissObjectID: NSManagedObjectID?
    @State private var gridCenteringRequest: PhotoGridCenteringRequest?
    @State private var visibleScrollDate: Date?
    @State private var isScrollDateVisible = false
    @State private var isScrollGestureActive = false
    @State private var firstGridItemFrameInGlobal: CGRect = .zero
    @State private var isSelectionMode = false
    @State private var selectedPhotoIDs: Set<NSManagedObjectID> = []
    @State private var isExporting = false
    @State private var isSavingToPhotoLibrary = false
    @State private var exportedFileURLs: [URL] = []
    @State private var showingExportPicker = false
    @State private var contextMenuSharePresentation: ActivityPresentation?
    @State private var portraitVideoExportPresentation: PortraitVideoExportPresentation?
    @State private var exportAlertMessage: String?
    @State private var showingDeleteConfirmation = false
    @State private var isDeletingSelection = false
    @State private var didSyncExifMetadata = false
    @State private var gridFilter: PhotoGridFilter = .all
    @State private var metadataSyncTask: Task<Void, Never>?
    private let enableScrollDateDebugLogs = false

    private static let shareTitleDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let shareFileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return formatter
    }()

    var body: some View {
        NavigationStack {
            ZStack {
                    if !dataController.hasAnyPhotos {
                        VStack(spacing: 20) {
                            if cloudSyncMonitor.isMetadataImportActive {
                                photoLibraryDownloadStatus
                            } else {
                                Image(systemName: "camera.fill")
                                    .font(.system(size: 60))
                                    .foregroundStyle(.secondary)

                                Text("No Photos Yet")
                                    .font(.title2)
                                    .fontWeight(.semibold)

                                Text("Start capturing your daily moments")
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                            }
                            
                            Button(action: openCamera) {
                                Label("Take Your First Photo", systemImage: "camera")
                                    .font(.headline)
                                    .padding()
                                    .background(.blue.gradient, in: Capsule())
                                    .foregroundStyle(.white)
                            }
                            .disabled(photoImporter.isImporting)
                            .accessibilityIdentifier("emptyStateCaptureButton")
                            .padding(.top)
                        }
                        .padding(.horizontal, 28)
                    } else if dataController.isEmpty {
                        filteredEmptyState
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .ignoresSafeArea(.container, edges: [.top, .bottom])
                    } else {
                        UIKitPhotoGridView(
                            dataController: dataController,
                            changeToken: dataController.changeToken,
                            centeringRequest: gridCenteringRequest,
                            isSelectionMode: $isSelectionMode,
                            selectedPhotoIDs: $selectedPhotoIDs,
                            onOpenPhoto: { objectID, _, _ in
                                openPhotoDetail(for: objectID)
                            },
                            onPhotoFrameChanged: { _, _ in },
                            onPhotoCentered: { objectID, frame in
                                handlePhotoCenteredForDetailDismiss(objectID: objectID, frame: frame)
                            },
                            onFirstItemFrameChanged: { frame in
                                if frame != .zero {
                                    firstGridItemFrameInGlobal = frame
                                }
                            },
                            onTopVisibleDateChanged: { date in
                                guard let date else { return }
                                if isScrollGestureActive {
                                    showScrollDateOverlay(for: date, direction: .none)
                                } else if visibleScrollDate == nil {
                                    visibleScrollDate = date
                                }
                            },
                            onScrollActivityChanged: { isActive in
                                isScrollGestureActive = isActive
                                if !isActive {
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        isScrollDateVisible = false
                                    }
                                }
                            },
                            onContextMenuAction: { action, objectID in
                                handlePhotoContextMenuAction(action, objectID: objectID)
                            }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .ignoresSafeArea(.container, edges: [.top, .bottom])
                        .overlay(alignment: .top) {
                            if isScrollDateVisible, let visibleScrollDate {
                                ScrollMonthOverlay(date: visibleScrollDate)
                                    .padding(.top, 12)
                                    .transition(.move(edge: .top).combined(with: .opacity))
                            }
                        }
                    }

            }
            .overlay(alignment: .bottom) {
                if dataController.hasAnyPhotos, !isSelectionMode {
                    floatingCaptureButton
                        .padding(.bottom, 20)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if dataController.hasAnyPhotos, !isSelectionMode {
                    floatingFilterButton
                        .padding(.leading, 18)
                        .padding(.bottom, 24)
                }
            }
            .overlay(alignment: .bottom) {
                if photoImporter.shouldShowOverlay {
                    PhotoImportProgressOverlay(importer: photoImporter)
                        .padding(.horizontal, 16)
                        .padding(.bottom, dataController.hasAnyPhotos ? 132 : 24)
                }
            }
            .navigationTitle("Work in Progress")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !dataController.isEmpty {
                        Button(isSelectionMode ? "Cancel" : "Select") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isSelectionMode.toggle()
                                if !isSelectionMode {
                                    selectedPhotoIDs.removeAll()
                                }
                            }
                        }
                    }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    if isSelectionMode {
                        Button(action: toggleHeartForSelectedPhotos) {
                            Image(systemName: selectedHeartButtonSystemName)
                                .font(.title3)
                        }
                        .foregroundStyle(selectedHeartButtonColor)
                        .disabled(!isSelectedHeartButtonEnabled)

                        Button(action: toggleFavoriteLivePhotoForSelectedPhotos) {
                            Image(uiImage: FavoriteLivePhotoFilterSymbol.image(isSelected: isSelectedFavoriteLivePhotoButtonActive))
                                .renderingMode(.template)
                                .font(.title3)
                        }
                        .foregroundStyle(selectedFavoriteLivePhotoButtonColor)
                        .disabled(!isSelectedFavoriteLivePhotoButtonEnabled)
                        .accessibilityLabel(isSelectedFavoriteLivePhotoButtonActive ? "Remove Favorite Live Photo" : "Favorite Live Photo")

                        Menu {
                            Button(action: exportSelectedPhotos) {
                                Label("Save Selected to Files (\(selectedPhotoIDs.count))", systemImage: "folder")
                            }
                            .disabled(selectedPhotoIDs.isEmpty || isExporting || isSavingToPhotoLibrary || isDeletingSelection)

                            Button(action: exportAllPhotos) {
                                Label("Save All to Files (\(dataController.totalPhotoCount))", systemImage: "folder")
                            }
                            .disabled(!dataController.hasAnyPhotos || isExporting || isSavingToPhotoLibrary || isDeletingSelection)

                            Divider()

                            Button(action: saveSelectedPhotosToLibrary) {
                                Label("Save Selected to Photos (\(selectedPhotoIDs.count))", systemImage: "square.and.arrow.down")
                            }
                            .disabled(selectedPhotoIDs.isEmpty || isExporting || isSavingToPhotoLibrary || isDeletingSelection)

                            Button(action: saveAllPhotosToLibrary) {
                                Label("Save All to Photos (\(dataController.totalPhotoCount))", systemImage: "photo.stack")
                            }
                            .disabled(!dataController.hasAnyPhotos || isExporting || isSavingToPhotoLibrary || isDeletingSelection)

                            Divider()

                            Button(role: .destructive, action: { showingDeleteConfirmation = true }) {
                                Label("Delete Selected (\(selectedPhotoIDs.count))", systemImage: "trash")
                            }
                            .disabled(selectedPhotoIDs.isEmpty || isDeletingSelection || isSavingToPhotoLibrary)
                        } label: {
                            if isExporting || isSavingToPhotoLibrary || isDeletingSelection {
                                ProgressView()
                            } else {
                                Image(systemName: "ellipsis.circle")
                                    .font(.title3)
                            }
                        }
                        .accessibilityLabel("More Selection Actions")
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
                    } else {
                        Button(action: openPortraitVideoExporter) {
                            Image(systemName: "film.stack")
                                .font(.title3)
                        }
                        .disabled(!dataController.hasAnyPhotos || photoImporter.isImporting)

                        Button(action: { showingNotificationSettings = true }) {
                            Image(systemName: "gearshape")
                                .font(.title3)
                        }
                    }
                }
            }
            .toolbar(photoDetailPresentation == nil ? .visible : .hidden, for: .navigationBar)
            .fullScreenCover(isPresented: $showingCamera) {
                ExperimentalCameraView(
                    gridTargetFrameInGlobal: firstGridItemFrameInGlobal == .zero ? nil : firstGridItemFrameInGlobal
                )
            }
            .sheet(isPresented: $showingNotificationSettings) {
                NotificationSettingsView()
            }
            .sheet(item: $portraitVideoExportPresentation) { presentation in
                PortraitVideoExportSheet(
                    photos: presentation.photos
                )
            }
            .fullScreenCover(item: $photoDetailPresentation) { presentation in
                photoDetailView(for: presentation)
            }
            .sheet(isPresented: $showingExportPicker, onDismiss: {
                exportedFileURLs = []
            }) {
                ExportDocumentPicker(urls: exportedFileURLs)
            }
            .sheet(item: $contextMenuSharePresentation) { presentation in
                ActivityView(activityItems: presentation.activityItems)
            }
            .alert("Photos", isPresented: Binding(
                get: { exportAlertMessage != nil },
                set: { if !$0 { exportAlertMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(exportAlertMessage ?? "")
            }
        }
        .onAppear {
            dataController.configureIfNeeded(
                context: viewContext,
                filter: gridFilter
            )
            openCameraIfNeededFromNotification()
            scheduleMetadataSyncIfNeeded()
        }
        .onChange(of: gridFilter) { _, newValue in
            selectedPhotoIDs.removeAll()
            pendingDetailDismissObjectID = nil
            gridCenteringRequest = nil
            dataController.setFilter(newValue)
        }
        .onChange(of: dataController.changeToken) { _, _ in
            scheduleMetadataSyncIfNeeded()
        }
        .onChange(of: photoDetailPresentation?.id) { _, newValue in
            if newValue == nil {
                scheduleMetadataSyncIfNeeded()
            } else {
                metadataSyncTask?.cancel()
                metadataSyncTask = nil
            }
        }
        .onChange(of: notificationNavigation.cameraOpenRequestToken) { _, token in
            guard token != nil else { return }
            openCameraIfNeededFromNotification()
        }
        .onDisappear {
            metadataSyncTask?.cancel()
            metadataSyncTask = nil
        }
    }

    private func openCameraIfNeededFromNotification() {
        guard notificationNavigation.cameraOpenRequestToken != nil else { return }
        guard !photoImporter.isImporting else {
            notificationNavigation.consumeCameraOpenRequest()
            return
        }
        showingCamera = true
        notificationNavigation.consumeCameraOpenRequest()
    }

    @MainActor
    private func openPhotoDetail(for objectID: NSManagedObjectID) {
        let items = dataController.itemsSnapshot.map(PhotoDetailItem.init(gridItem:))
        guard let index = items.firstIndex(where: { $0.objectID == objectID }) else {
            return
        }

        activePhotoDetailObjectID = objectID
        withAnimation(.easeInOut(duration: 0.2)) {
            photoDetailPresentation = PhotoDetailPresentation(
                items: items,
                initialIndex: index
            )
        }
    }

    @ViewBuilder
    private func photoDetailView(for presentation: PhotoDetailPresentation) -> some View {
        NavigationStack {
            PhotoDetailView(
                items: presentation.items,
                initialIndex: presentation.initialIndex,
                onClose: closePhotoDetail,
                onCurrentItemChanged: { objectID in
                    activePhotoDetailObjectID = objectID
                }
            )
            .toolbarBackground(.visible, for: .navigationBar, .bottomBar)
            .toolbarColorScheme(.dark, for: .navigationBar, .bottomBar)
        }
    }

    private func closePhotoDetail(_ objectID: NSManagedObjectID?) {
        guard photoDetailPresentation != nil else { return }
        guard let objectID else {
            finalizePhotoDetailDismissal()
            return
        }

        pendingDetailDismissObjectID = objectID
        gridCenteringRequest = PhotoGridCenteringRequest(objectID: objectID, token: UUID())
    }

    private func handlePhotoCenteredForDetailDismiss(objectID: NSManagedObjectID, frame: CGRect) {
        guard pendingDetailDismissObjectID == objectID else { return }
        pendingDetailDismissObjectID = nil
        withAnimation(.easeInOut(duration: 0.18)) {
            finalizePhotoDetailDismissal()
        }
    }

    private func finalizePhotoDetailDismissal() {
        activePhotoDetailObjectID = nil
        photoDetailPresentation = nil
    }

    private var filteredEmptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: gridFilter.systemImage)
                .font(.system(size: 56))
                .foregroundStyle(.secondary)

            Text(emptyStateTitle)
                .font(.title2.weight(.semibold))

            Text(emptyStateMessage)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    private var photoLibraryDownloadStatus: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
                .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text("Downloading Photo Library")
                    .font(.headline)

                Text("Photos, metadata, and thumbnails are coming down from iCloud.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.secondary.opacity(0.16))
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("photoLibraryDownloadStatus")
    }

    private var emptyStateTitle: String {
        switch gridFilter {
        case .all:
            return "No Photos Yet"
        case .hearted:
            return "No Hearted Photos"
        case .favoriteLivePhotos:
            return "No Favorite Live Photos"
        }
    }

    private var emptyStateMessage: String {
        switch gridFilter {
        case .all:
            return "Start capturing your daily moments."
        case .hearted:
            return "Heart photos from the detail view to focus this grid."
        case .favoriteLivePhotos:
            return "Mark Live Photos from the detail view to use their video clips."
        }
    }

    private var floatingFilterButton: some View {
        Menu {
            ForEach(PhotoGridFilter.allCases) { filter in
                Button {
                    gridFilter = filter
                } label: {
                    Label {
                        Text(filter.title)
                    } icon: {
                        filterMenuSymbol(for: filter)
                    }
                }
            }
        } label: {
            filterButtonLabel
        }
        .contentShape(.circle)
        .buttonStyle(floatingCaptureButtonStyle)
        .accessibilityLabel("Filter Photos")
        .accessibilityValue(gridFilter.title)
        .accessibilityIdentifier("gridFilterButton")
    }

    @ViewBuilder
    private func filterMenuSymbol(for filter: PhotoGridFilter) -> some View {
        if filter == .favoriteLivePhotos {
            Image(uiImage: FavoriteLivePhotoFilterSymbol.image(isSelected: true))
                .renderingMode(.template)
        } else if filter == .all {
            Image(systemName: "photo.stack")
        } else {
            Image(systemName: filter.systemImage)
        }
    }

    @ViewBuilder
    private var filterButtonLabel: some View {
        if #available(iOS 26.0, *) {
            filterButtonSymbol
                .frame(width: 42, height: 42)
                .background(
                    Circle()
                        .fill(.clear)
                )
                .shadow(color: .black.opacity(0.1), radius: 12, y: 7)
        } else {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)

                Circle()
                    .stroke(Color.white.opacity(0.5), lineWidth: 1)

                filterButtonSymbol
            }
            .frame(width: 42, height: 42)
            .shadow(color: .black.opacity(0.12), radius: 12, y: 7)
        }
    }

    @ViewBuilder
    private var filterButtonSymbol: some View {
        if gridFilter == .favoriteLivePhotos {
            Image(uiImage: FavoriteLivePhotoFilterSymbol.image(isSelected: true))
                .renderingMode(.template)
                .foregroundStyle(filterButtonForegroundStyle)
        } else {
            Image(systemName: gridFilter.systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(filterButtonForegroundStyle)
        }
    }

    private var filterButtonForegroundStyle: Color {
        switch gridFilter {
        case .all:
            return .primary
        case .hearted:
            return .red
        case .favoriteLivePhotos:
            return .blue
        }
    }

    private var floatingCaptureButton: some View {
        Button(action: openCamera) {
            captureButtonLabel
        }
        .contentShape(.circle)
        .buttonStyle(floatingCaptureButtonStyle)
        .disabled(photoImporter.isImporting)
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

    private func openCamera() {
        guard !photoImporter.isImporting else {
            exportAlertMessage = "Photo import is still running. Wait for it to finish before capturing."
            return
        }
        showingCamera = true
    }

    @MainActor
    private func scheduleMetadataSyncIfNeeded() {
        guard photoDetailPresentation == nil else { return }
        guard !didSyncExifMetadata else { return }
        guard !dataController.isEmpty else { return }
        guard metadataSyncTask == nil else { return }

        metadataSyncTask = Task(priority: .utility) {
            defer {
                Task { @MainActor in
                    metadataSyncTask = nil
                }
            }

            try? await Task.sleep(for: .seconds(0.8))
            guard !Task.isCancelled else { return }
            await syncPhotoMetadataFromExifIfNeeded()
        }
    }

    private func syncPhotoMetadataFromExifIfNeeded() async {
        guard !didSyncExifMetadata else { return }
        guard !dataController.isEmpty else { return }
        await PhotoStorageService.shared.syncPhotoMetadataFromAssetsIfNeeded(limit: 24)
        guard !Task.isCancelled else { return }
        await MainActor.run {
            didSyncExifMetadata = true
        }
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
            print("ScrollMonthOverlay update current=\(current) next=\(debugMonthYear(date)) direction=\(direction.rawValue)")
        }
        visibleScrollDate = date

        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            isScrollDateVisible = true
        }
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
    private func exportSelectedPhotos() {
        let selectedPhotos = dataController.photos(for: selectedPhotoIDs)
        guard !selectedPhotos.isEmpty else {
            exportAlertMessage = "Please select at least one photo to export."
            return
        }
        startExport(for: selectedPhotos)
    }

    private var selectedPhotos: [DailyPhoto] {
        dataController.photos(for: selectedPhotoIDs)
    }

    private var selectedLivePhotos: [DailyPhoto] {
        selectedPhotos.filter { $0.livePhotoImageAssetName != nil && $0.livePhotoVideoAssetName != nil }
    }

    private var shouldHeartSelectedPhotos: Bool {
        dataController.shouldHeartPhotos(for: selectedPhotoIDs)
    }

    private var shouldFavoriteSelectedLivePhotos: Bool {
        let photos = selectedLivePhotos
        guard !photos.isEmpty else { return true }
        return photos.contains { !$0.isFavoriteLivePhoto }
    }

    private var selectedHeartButtonSystemName: String {
        shouldHeartSelectedPhotos ? "heart" : "heart.fill"
    }

    private var selectedHeartButtonColor: Color {
        guard isSelectedHeartButtonEnabled else { return .secondary }
        return shouldHeartSelectedPhotos ? Color.primary : Color.red
    }

    private var isSelectedFavoriteLivePhotoButtonActive: Bool {
        !shouldFavoriteSelectedLivePhotos
    }

    private var selectedFavoriteLivePhotoButtonColor: Color {
        guard isSelectedFavoriteLivePhotoButtonEnabled else { return .secondary }
        return isSelectedFavoriteLivePhotoButtonActive ? Color.blue : Color.primary
    }

    private var isSelectedHeartButtonEnabled: Bool {
        !selectedPhotoIDs.isEmpty && !isDeletingSelection && !isSavingToPhotoLibrary
    }

    private var isSelectedFavoriteLivePhotoButtonEnabled: Bool {
        !selectedLivePhotos.isEmpty && !isDeletingSelection && !isSavingToPhotoLibrary
    }

    private func toggleHeartForSelectedPhotos() {
        let photos = selectedPhotos
        guard !photos.isEmpty else {
            exportAlertMessage = "Please select at least one photo."
            return
        }

        let nextValue = shouldHeartSelectedPhotos
        let now = Date()

        do {
            for photo in photos {
                photo.isHearted = nextValue
                photo.modifiedAt = now
            }
            try viewContext.save()
            selectedPhotoIDs.removeAll()
            isSelectionMode = false
        } catch {
            viewContext.rollback()
            exportAlertMessage = "Unable to update favorites."
        }
    }

    private func toggleFavoriteLivePhotoForSelectedPhotos() {
        let photos = selectedLivePhotos
        guard !photos.isEmpty else {
            exportAlertMessage = "Please select at least one Live Photo."
            return
        }

        let nextValue = shouldFavoriteSelectedLivePhotos
        let now = Date()

        do {
            for photo in photos {
                photo.isFavoriteLivePhoto = nextValue
                photo.modifiedAt = now
            }
            try viewContext.save()
            selectedPhotoIDs.removeAll()
            isSelectionMode = false
        } catch {
            viewContext.rollback()
            exportAlertMessage = "Unable to update Favorite Live Photos."
        }
    }

    private func openPortraitVideoExporter() {
        guard !photoImporter.isImporting else {
            exportAlertMessage = "Photo import is still running. Wait for it to finish before creating a video."
            return
        }
        portraitVideoExportPresentation = PortraitVideoExportPresentation(
            photos: dataController.allStoredPhotos().map(PortraitVideoExportItem.init(photo:))
        )
    }

    private func exportAllPhotos() {
        let allPhotos = dataController.allStoredPhotos()
        guard !allPhotos.isEmpty else {
            exportAlertMessage = "No photos available to export."
            return
        }
        startExport(for: allPhotos)
    }

    private func handlePhotoContextMenuAction(_ action: PhotoGridContextAction, objectID: NSManagedObjectID) {
        switch action {
        case .share:
            shareContextMenuPhoto(objectID)
        case .save:
            saveContextMenuPhoto(objectID)
        case .copy:
            copyContextMenuPhoto(objectID)
        case .delete:
            deleteContextMenuPhoto(objectID)
        }
    }

    private func shareContextMenuPhoto(_ objectID: NSManagedObjectID) {
        guard !isExporting else { return }
        guard let photo = photo(for: objectID) else {
            exportAlertMessage = "Unable to find this photo."
            return
        }

        isExporting = true
        Task { @MainActor in
            do {
                let url = try await PhotoStorageService.shared.prepareStillPhotoShareURL(
                    fullImageAssetName: photo.fullImageAssetName ?? photo.livePhotoImageAssetName
                )
                let shareItems = [
                    try StillPhotoShareItemFactory.makeItem(
                        sourceURL: url,
                        title: shareTitle(for: photo),
                        subject: shareSubject(for: photo),
                        fileTitle: shareFileTitle(for: photo)
                    )
                ]
                contextMenuSharePresentation = ActivityPresentation(activityItems: shareItems)
                isExporting = false
            } catch {
                exportAlertMessage = "Share failed: \(error.localizedDescription)"
                isExporting = false
            }
        }
    }

    private func shareTitle(for photo: DailyPhoto) -> String {
        guard let captureDate = photo.captureDate else { return "Progress Photo" }
        return "Progress Photo - \(Self.shareTitleDateFormatter.string(from: captureDate))"
    }

    private func shareSubject(for photo: DailyPhoto) -> String {
        if let locationName = photo.locationName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !locationName.isEmpty {
            return "\(shareTitle(for: photo)) at \(locationName)"
        }
        return shareTitle(for: photo)
    }

    private func shareFileTitle(for photo: DailyPhoto) -> String {
        guard let captureDate = photo.captureDate else { return "Progress Photo" }
        return "Progress Photo \(Self.shareFileDateFormatter.string(from: captureDate))"
    }

    private func saveContextMenuPhoto(_ objectID: NSManagedObjectID) {
        guard let photo = photo(for: objectID) else {
            exportAlertMessage = "Unable to find this photo."
            return
        }
        startPhotoLibrarySave(for: [photo], exitsSelectionMode: false)
    }

    private func copyContextMenuPhoto(_ objectID: NSManagedObjectID) {
        guard let photo = photo(for: objectID) else {
            exportAlertMessage = "Unable to find this photo."
            return
        }

        let assetName = photo.fullImageAssetName ?? photo.livePhotoImageAssetName
        Task { @MainActor in
            do {
                let image = try await PhotoStorageService.shared.loadFullImage(named: assetName)
                UIPasteboard.general.image = image
            } catch {
                exportAlertMessage = "Copy failed: \(error.localizedDescription)"
            }
        }
    }

    private func saveSelectedPhotosToLibrary() {
        let photos = selectedPhotos
        guard !photos.isEmpty else {
            exportAlertMessage = "Please select at least one photo to save."
            return
        }
        startPhotoLibrarySave(for: photos)
    }

    private func saveAllPhotosToLibrary() {
        let photos = dataController.allStoredPhotos()
        guard !photos.isEmpty else {
            exportAlertMessage = "No photos available to save."
            return
        }
        startPhotoLibrarySave(for: photos)
    }

    private func deleteContextMenuPhoto(_ objectID: NSManagedObjectID) {
        Task { @MainActor in
            do {
                try await PhotoStorageService.shared.deletePhoto(objectID, context: viewContext)
                selectedPhotoIDs.remove(objectID)
            } catch {
                exportAlertMessage = "Delete failed: \(error.localizedDescription)"
            }
        }
    }

    private func photo(for objectID: NSManagedObjectID) -> DailyPhoto? {
        (try? viewContext.existingObject(with: objectID)) as? DailyPhoto
    }

    private func deleteSelectedPhotos() {
        guard !isDeletingSelection else { return }

        let photosToDelete = dataController.photos(for: selectedPhotoIDs)
        guard !photosToDelete.isEmpty else {
            exportAlertMessage = "Please select at least one photo to delete."
            return
        }

        isDeletingSelection = true
        let photoIDsToDelete = photosToDelete.map(\.objectID)

        Task { @MainActor in
            do {
                _ = try await PhotoStorageService.shared.deletePhotos(
                    photoIDsToDelete,
                    context: viewContext,
                    deletesAssetsInBackground: true
                )

                isDeletingSelection = false
                isSelectionMode = false
                selectedPhotoIDs.removeAll()
            } catch {
                isDeletingSelection = false
                exportAlertMessage = "Delete failed: \(error.localizedDescription)"
            }
        }
    }

    private func startPhotoLibrarySave(
        for photosToSave: [DailyPhoto],
        exitsSelectionMode: Bool = true
    ) {
        guard !isSavingToPhotoLibrary, !isExporting, !isDeletingSelection else { return }
        isSavingToPhotoLibrary = true

        Task { @MainActor in
            do {
                let savedCount = try await PhotoLibrarySaveService.shared.save(photosToSave)
                exportAlertMessage = "Saved \(savedCount) photo\(savedCount == 1 ? "" : "s") to Photos."
                if exitsSelectionMode {
                    isSelectionMode = false
                    selectedPhotoIDs.removeAll()
                }
                isSavingToPhotoLibrary = false
            } catch let error as PhotoLibrarySaveError {
                exportAlertMessage = error.localizedDescription
                isSavingToPhotoLibrary = false
            } catch {
                exportAlertMessage = "Save failed: \(error.localizedDescription)"
                isSavingToPhotoLibrary = false
            }
        }
    }

    private func startExport(for photosToExport: [DailyPhoto]) {
        guard !isExporting, !isSavingToPhotoLibrary else { return }
        isExporting = true

        Task { @MainActor in
            do {
                let urls = try await PhotoStorageService.shared.prepareExportFiles(for: photosToExport)
                exportedFileURLs = urls
                showingExportPicker = !urls.isEmpty
                if urls.isEmpty {
                    exportAlertMessage = "Nothing was exported."
                } else {
                    isSelectionMode = false
                    selectedPhotoIDs.removeAll()
                }
                isExporting = false
            } catch {
                exportAlertMessage = "Export failed: \(error.localizedDescription)"
                isExporting = false
            }
        }
    }
}

private enum FavoriteLivePhotoFilterSymbol {
    static func image(isSelected: Bool) -> UIImage {
        let livePhotoConfiguration = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        let heartConfiguration = UIImage.SymbolConfiguration(pointSize: 10, weight: .bold)
        guard let livePhoto = UIImage(systemName: "livephoto", withConfiguration: livePhotoConfiguration),
              let heart = UIImage(systemName: isSelected ? "heart.fill" : "heart", withConfiguration: heartConfiguration) else {
            return UIImage(systemName: "livephoto") ?? UIImage()
        }

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24))
        let image = renderer.image { _ in
            UIColor.white.set()
            livePhoto.draw(in: CGRect(x: 1, y: 1, width: 19, height: 19))
            heart.draw(in: CGRect(x: 12, y: 11, width: 11, height: 11))
        }
        return image.withRenderingMode(.alwaysTemplate)
    }
}

private enum OverlayScrollDirection: String {
    case up
    case down
    case none
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
