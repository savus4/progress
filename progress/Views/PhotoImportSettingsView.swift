import PhotosUI
import SwiftUI

struct PhotoImportSettingsView: View {
    @StateObject private var photoImporter = PhotoImportCoordinator.shared
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var selectedPrivatePhotoItems: [PhotosPickerItem] = []
    @State private var showingAlbumImportSheet = false
    @State private var availableImportAlbums: [PhotoImportAlbum] = []
    @State private var isLoadingImportAlbums = false

    var body: some View {
        Form {
            Section {
                PhotosPicker(
                    selection: $selectedPhotoItems,
                    maxSelectionCount: nil,
                    matching: .any(of: [.images, .livePhotos]),
                    photoLibrary: .shared()
                ) {
                    Label("Import Photos", systemImage: "photo.on.rectangle.angled")
                }
                .disabled(photoImporter.isImporting)

                Button {
                    presentAlbumImportSheet()
                } label: {
                    Label("Import Album", systemImage: "rectangle.stack")
                }
                .disabled(photoImporter.isImporting || isLoadingImportAlbums)

                PhotosPicker(
                    selection: $selectedPrivatePhotoItems,
                    maxSelectionCount: nil,
                    matching: .any(of: [.images, .livePhotos]),
                    photoLibrary: .shared()
                ) {
                    Label("Import Privately (No Live Photos)", systemImage: "lock.shield")
                }
                .disabled(photoImporter.isImporting)

                importGuidanceCard

                if let statusMessage = photoImporter.statusMessage {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Import")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if photoImporter.shouldShowOverlay {
                PhotoImportProgressOverlay(importer: photoImporter)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
            }
        }
        .onChange(of: selectedPhotoItems) { _, items in
            guard !items.isEmpty else { return }
            photoImporter.importSelectedPhotos(items)
            selectedPhotoItems = []
        }
        .onChange(of: selectedPrivatePhotoItems) { _, items in
            guard !items.isEmpty else { return }
            photoImporter.importSelectedPhotosPrivately(items)
            selectedPrivatePhotoItems = []
        }
        .sheet(isPresented: $showingAlbumImportSheet) {
            NavigationStack {
                List(availableImportAlbums) { album in
                    Button {
                        showingAlbumImportSheet = false
                        photoImporter.importAlbum(album)
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(album.title)
                                    .foregroundStyle(.primary)
                                Text("\(album.assetCount) photo\(album.assetCount == 1 ? "" : "s")")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .navigationTitle("Import Album")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            showingAlbumImportSheet = false
                        }
                    }
                }
            }
        }
    }

    private var importGuidanceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            importGuidanceRow(
                systemImage: "livephoto",
                title: "Live Photos",
                detail: "\"Import Photos\" and \"Import Album\" keep Live Photos, great for video creation.",
                tint: .blue
            )

            Divider()

            importGuidanceRow(
                systemImage: "photo",
                title: "Private Import",
                detail: "\"Import Privately\" saves still images only, and you can import without full Photos library access.",
                tint: .orange
            )

            Divider()

            importGuidanceRow(
                systemImage: "lock.shield",
                title: "Your Data",
                detail: "Photos stay on this device and, when enabled, in your iCloud.",
                tint: .green
            )
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private func importGuidanceRow(
        systemImage: String,
        title: String,
        detail: String,
        tint: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 16)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.footnote.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func presentAlbumImportSheet() {
        guard !photoImporter.isImporting, !isLoadingImportAlbums else { return }
        isLoadingImportAlbums = true
        Task {
            availableImportAlbums = await photoImporter.requestImportAlbums()
            isLoadingImportAlbums = false
            showingAlbumImportSheet = !availableImportAlbums.isEmpty
        }
    }
}
