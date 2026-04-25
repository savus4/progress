import SwiftUI
import CoreData
import Combine

private struct PhotoPagerSelection: Identifiable {
    let objectID: NSManagedObjectID
    var id: String { objectID.uriRepresentation().absoluteString }
}

struct PhotoGridView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @ObservedObject private var notificationNavigation = NotificationNavigationCoordinator.shared
    @StateObject private var dataController = PhotoGridDataController()

    @State private var showingCamera = false
    @State private var showingNotificationSettings = false
    @State private var photoPagerSelection: PhotoPagerSelection?
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
    @State private var didSyncExifMetadata = false
    @State private var activeDownloadAssetNames: Set<String> = []
    private let enableScrollDateDebugLogs = false

    var body: some View {
        NavigationStack {
            ZStack {
                if dataController.isEmpty {
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
                    UIKitPhotoGridView(
                        dataController: dataController,
                        changeToken: dataController.changeToken,
                        activeDownloadAssetNames: activeDownloadAssetNames,
                        isSelectionMode: $isSelectionMode,
                        selectedPhotoIDs: $selectedPhotoIDs,
                        onOpenPhoto: { objectID in
                            photoPagerSelection = PhotoPagerSelection(objectID: objectID)
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
                    .overlay(alignment: .bottom) {
                        if !isSelectionMode {
                            floatingCaptureButton
                                .padding(.bottom, 20)
                        }
                    }
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
                        Menu {
                            Button(action: exportSelectedPhotos) {
                                Label("Export Selected (\(selectedPhotoIDs.count))", systemImage: "square.and.arrow.up")
                            }
                            .disabled(selectedPhotoIDs.isEmpty || isExporting)

                            Button(action: exportAllPhotos) {
                                Label("Export All (\(dataController.photoCount))", systemImage: "tray.and.arrow.down")
                            }
                            .disabled(dataController.isEmpty || isExporting)
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
            .sheet(item: $photoPagerSelection) { selection in
                PhotoPagerView(
                    photos: dataController.allPhotos,
                    initialPhotoID: selection.objectID
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
            dataController.configureIfNeeded(context: viewContext)
            syncActiveDownloadSnapshot()
            openCameraIfNeededFromNotification()
        }
        .onChange(of: notificationNavigation.cameraOpenRequestToken) { _, token in
            guard token != nil else { return }
            openCameraIfNeededFromNotification()
        }
        .onReceive(NotificationCenter.default.publisher(for: CloudKitService.assetTransferDidChangeNotification)) { notification in
            handleAssetTransferNotification(notification)
        }
        .task {
            await syncPhotoMetadataFromExifIfNeeded()
        }
    }

    @MainActor
    private func syncActiveDownloadSnapshot() {
        activeDownloadAssetNames = CloudSyncMonitor.shared.activeDownloadAssetNamesSnapshot
    }

    private func openCameraIfNeededFromNotification() {
        guard notificationNavigation.cameraOpenRequestToken != nil else { return }
        showingCamera = true
        notificationNavigation.consumeCameraOpenRequest()
    }

    @MainActor
    private func handleAssetTransferNotification(_ notification: Notification) {
        guard let kindRawValue = notification.userInfo?["kind"] as? String,
              let phaseRawValue = notification.userInfo?["phase"] as? String,
              let assetName = notification.userInfo?["assetName"] as? String,
              let kind = CloudKitService.AssetTransferKind(rawValue: kindRawValue),
              let phase = CloudKitService.AssetTransferPhase(rawValue: phaseRawValue),
              kind == .download else {
            return
        }

        switch phase {
        case .started:
            activeDownloadAssetNames.insert(assetName)
        case .finished, .failed:
            activeDownloadAssetNames.remove(assetName)
        }
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
        guard !dataController.isEmpty else { return }
        didSyncExifMetadata = true
        await PhotoStorageService.shared.syncPhotoMetadataFromAssetsIfNeeded()
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

    private func exportAllPhotos() {
        let allPhotos = dataController.allPhotos
        guard !allPhotos.isEmpty else {
            exportAlertMessage = "No photos available to export."
            return
        }
        startExport(for: allPhotos)
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
                for photoID in photoIDsToDelete {
                    try await PhotoStorageService.shared.deletePhoto(photoID, context: viewContext)
                }

                isDeletingSelection = false
                isSelectionMode = false
                selectedPhotoIDs.removeAll()
            } catch {
                isDeletingSelection = false
                exportAlertMessage = "Delete failed: \(error.localizedDescription)"
            }
        }
    }

    private func startExport(for photosToExport: [DailyPhoto]) {
        guard !isExporting else { return }
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
