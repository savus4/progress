import PhotosUI
import SwiftUI

struct PhotoImportSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let timelineID: UUID
    private let resumeMethod: PhotoImportMethod?
    @StateObject private var photoImporter = PhotoImportCoordinator.shared
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var pickerMethod = PhotoImportMethod.photos
    @State private var showingPhotoPicker = false
    @State private var showingAlbumImportSheet = false
    @State private var availableImportAlbums: [PhotoImportAlbum] = []
    @State private var preparingMethod: PhotoImportMethod?
    @State private var pendingMethod: PhotoImportMethod?
    @State private var authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var showingAccessAlert = false
    @State private var resumeAfterSettings = false
    @State private var didResume = false

    init(timelineID: UUID = TimelineIdentity.defaultID, resuming method: PhotoImportMethod? = nil) {
        self.timelineID = timelineID
        resumeMethod = method
    }

    var body: some View {
        Form {
            ForEach(visibleImportMethods) { method in
                Section {
                    Button {
                        prepareImport(method)
                    } label: {
                        PhotoImportOptionRow(
                            method: method,
                            hasFullAccess: authorizationStatus == .authorized,
                            isPreparing: preparingMethod == method
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(method.title)
                    .accessibilityValue(accessibilityDetail(for: method))
                    .disabled(photoImporter.isImporting || preparingMethod != nil)
                }
            }

            if let statusMessage = photoImporter.statusMessage {
                Section {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Import")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if resumeMethod != nil {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if photoImporter.shouldShowOverlay {
                PhotoImportProgressOverlay(importer: photoImporter)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
            }
        }
        .photosPicker(
            isPresented: $showingPhotoPicker,
            selection: $selectedPhotoItems,
            maxSelectionCount: nil,
            matching: .images,
            photoLibrary: .shared()
        )
        .onChange(of: selectedPhotoItems) { _, items in
            guard !items.isEmpty else { return }
            if pickerMethod == .privatePhotos {
                photoImporter.importSelectedPhotosPrivately(items, timelineID: timelineID)
            } else {
                photoImporter.importSelectedPhotos(items, timelineID: timelineID)
            }
            selectedPhotoItems = []
        }
        .sheet(isPresented: $showingAlbumImportSheet) {
            PhotoImportAlbumSheet(albums: availableImportAlbums, timelineID: timelineID)
        }
        .alert("Full Photos Access Needed", isPresented: $showingAccessAlert) {
            if authorizationStatus != .restricted {
                Button("Open Settings") {
                    guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
                    guard let method = pendingMethod else { return }
                    PhotoImportSettingsRecovery.save(PhotoImportResumeRequest(
                        method: method, timelineID: timelineID, createdAt: Date()
                    ))
                    resumeAfterSettings = true
                    Task { @MainActor in
                        let didOpen = await UIApplication.shared.open(settingsURL)
                        if !didOpen {
                            resumeAfterSettings = false
                            PhotoImportSettingsRecovery.clear()
                        }
                    }
                }
            }
            Button("Import Privately") {
                pendingMethod = nil
                prepareImport(.privatePhotos)
            }
            Button("Cancel", role: .cancel) { pendingMethod = nil }
        } message: {
            if authorizationStatus == .restricted {
                Text("Photos access is restricted on this device. You can still import privately as still photos.")
            } else {
                Text("In Settings, choose Apps → \(appName) → Photos → Full Access. Or import privately as still photos.")
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            refreshAuthorization()
            guard resumeAfterSettings else { return }
            resumeAfterSettings = false
            PhotoImportSettingsRecovery.clear()
            if authorizationStatus == .authorized, let method = pendingMethod {
                pendingMethod = nil
                prepareImport(method)
            }
        }
        .onAppear { refreshAuthorization() }
        .task {
            guard !didResume, let resumeMethod else { return }
            didResume = true
            refreshAuthorization()
            if authorizationStatus == .authorized { prepareImport(resumeMethod) }
        }
    }

    private func accessibilityDetail(for method: PhotoImportMethod) -> String {
        guard method.requiresFullAccess else { return "Still photos only. No library access needed." }
        return authorizationStatus == .authorized
            ? "Includes Live Photos. Full Photos access enabled."
            : "Includes Live Photos. Requires Full Photos access."
    }

    private var visibleImportMethods: [PhotoImportMethod] {
        PhotoImportMethod.allCases.filter { method in
            authorizationStatus != .authorized || method != .privatePhotos
        }
    }

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Work in Progress"
    }

    private func refreshAuthorization() {
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    private func prepareImport(_ method: PhotoImportMethod) {
        guard !photoImporter.isImporting, preparingMethod == nil else { return }
        preparingMethod = method
        Task { @MainActor in
            defer { preparingMethod = nil }
            let canImport = await PhotoImportAuthorization.authorize(method)
            if method.requiresFullAccess { refreshAuthorization() }
            guard canImport else {
                pendingMethod = method
                showingAccessAlert = true
                return
            }

            pendingMethod = nil
            switch method {
            case .photos, .privatePhotos:
                pickerMethod = method
                showingPhotoPicker = true
            case .album:
                availableImportAlbums = photoImporter.importAlbums()
                showingAlbumImportSheet = true
            }
        }
    }
}
