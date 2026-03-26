import SwiftUI
import CoreData
import MapKit
import Photos
import ImageIO

struct PhotoPagerView: View {
    let photos: [DailyPhoto]
    @Binding var selectedIndex: Int

    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss

    @State private var currentPage: Int?
    @State private var locationName = "Unknown location"
    @State private var showsMetadataPanel = false
    @State private var sharePayload: SharePayload?
    @State private var isPreparingShare = false
    @State private var shareStatusMessage: String?
    @State private var shareStatusToastTask: Task<Void, Never>?
    @State private var showingDeleteConfirmation = false
    @State private var isDeleting = false

    private static let navigationDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d, HH:mm")
        return formatter
    }()

    private var currentPhoto: DailyPhoto? {
        guard photos.indices.contains(selectedIndex) else { return nil }
        return photos[selectedIndex]
    }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ZStack(alignment: .bottom) {
                    Color.black.ignoresSafeArea()

                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 0) {
                            ForEach(photos.indices, id: \.self) { index in
                                PhotoPagerPageView(
                                    photo: photos[index],
                                    bottomInset: 16
                                )
                                .frame(width: proxy.size.width, height: proxy.size.height)
                                .tag(index)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.paging)
                    .scrollIndicators(.hidden)
                    .scrollPosition(id: $currentPage)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .foregroundStyle(.white)
                }

                ToolbarItemGroup(placement: .primaryAction) {
                    HStack(spacing: 0) {
                        Menu {
                            Button(action: saveToPhotosLibrary) {
                                Label("Save Live Photo", systemImage: "square.and.arrow.down")
                            }
                            .disabled(isPreparingShare || currentPhoto == nil)

                            Button(action: shareStillPhoto) {
                                Label("Share Photo", systemImage: "photo")
                            }
                            .disabled(isPreparingShare || currentPhoto == nil)

                            Button(action: shareLivePhotoFiles) {
                                Label("Share Photo + Video", systemImage: "livephoto")
                            }
                            .disabled(isPreparingShare || currentPhoto == nil)

                            Button {
                                showsMetadataPanel = true
                            } label: {
                                Label("Info", systemImage: "info.circle")
                            }
                            .disabled(currentPhoto == nil)
                        } label: {
                            if isPreparingShare {
                                ProgressView()
                            } else {
                                Image(systemName: "ellipsis.circle")
                                    .foregroundStyle(.white)
                            }
                        }
                        .frame(width: 44)

                        Button(role: .destructive) {
                            showingDeleteConfirmation = true
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.white)
                        }
                        .disabled(isDeleting || currentPhoto == nil)
                        .frame(width: 44)
                    }
                    .frame(width: 88, alignment: .trailing)
                }

                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text(navigationDateTitle)
                            .font(.headline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        Text(locationName)
                            .font(.caption)
                            .foregroundStyle(.gray)
                            .lineLimit(1)
                    }
                }
            }
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .overlay(alignment: .top) {
                if let shareStatusMessage {
                    ShareStatusToast(
                        message: shareStatusMessage,
                        isError: shareStatusMessage.localizedCaseInsensitiveContains("failed") ||
                            shareStatusMessage.localizedCaseInsensitiveContains("required")
                    )
                    .padding(.top, 12)
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .sheet(isPresented: $showsMetadataPanel) {
            metadataSheet
        }
        .onAppear {
            currentPage = selectedIndex
            Task {
                await loadLocationName()
            }
        }
        .onChange(of: currentPage) { _, newValue in
            guard let newValue else { return }
            selectedIndex = newValue
            Task {
                await loadLocationName()
            }
        }
        .onChange(of: selectedIndex) { _, newValue in
            if currentPage != newValue {
                currentPage = newValue
            }
        }
        .sheet(item: $sharePayload) { payload in
            ActivityView(activityItems: payload.items)
        }
        .confirmationDialog(
            "Delete photo?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Photo", role: .destructive) {
                deletePhoto()
            }
            .disabled(isDeleting)

            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone.")
        }
        .onChange(of: shareStatusMessage) { _, newValue in
            shareStatusToastTask?.cancel()
            guard newValue != nil else { return }
            shareStatusToastTask = Task {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        shareStatusMessage = nil
                    }
                }
            }
        }
    }

    private var navigationDateTitle: String {
        guard let captureDate = currentPhoto?.captureDate else { return "Unknown date" }
        return Self.navigationDateFormatter.string(from: captureDate)
    }

    @ViewBuilder
    private var metadataSheet: some View {
        if let currentPhoto {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        metadataSummaryCard(for: currentPhoto)

                        if currentPhoto.latitude != 0 && currentPhoto.longitude != 0 {
                            metadataMapCard(for: currentPhoto)
                        }

                        metadataDetailsCard(for: currentPhoto)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 28)
                }
                .navigationTitle("Info")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showsMetadataPanel = false
                        } label: {
                            Image(systemName: "xmark")
                        }
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(.thickMaterial)
            .presentationCornerRadius(28)
        }
    }

    private func metadataSummaryCard(for photo: DailyPhoto) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(photo.captureDate?.formatted(date: .complete, time: .shortened) ?? "Unknown date")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)

            Label(locationName, systemImage: "mappin.and.ellipse")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Divider()
            HStack(spacing: 12) {
                metadataPill(title: "Photo", systemImage: "photo")
                #if !targetEnvironment(simulator)
                if photo.livePhotoVideoAssetName != nil {
                    metadataPill(title: "Live Photo", systemImage: "livephoto")
                }
                #endif
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func metadataMapCard(for photo: DailyPhoto) -> some View {
        let coordinate = CLLocationCoordinate2D(latitude: photo.latitude, longitude: photo.longitude)

        return VStack(alignment: .leading, spacing: 12) {
            Text("Location")
                .font(.headline)
                .foregroundStyle(.primary)

            Map(initialPosition: .region(MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            ))) {
                Marker(locationName, coordinate: coordinate)
            }
            .frame(height: 240)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .onTapGesture {
                openLocationInMaps()
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func metadataDetailsCard(for photo: DailyPhoto) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Details")
                .font(.headline)
                .foregroundStyle(.primary)

            metadataDetailRow(
                title: "Captured",
                value: photo.captureDate?.formatted(date: .abbreviated, time: .shortened) ?? "Unknown"
            )
            metadataDetailRow(
                title: "Latitude",
                value: photo.latitude == 0 && photo.longitude == 0 ? "Unavailable" : String(format: "%.5f", photo.latitude)
            )
            metadataDetailRow(
                title: "Longitude",
                value: photo.latitude == 0 && photo.longitude == 0 ? "Unavailable" : String(format: "%.5f", photo.longitude)
            )
            #if !targetEnvironment(simulator)
            metadataDetailRow(
                title: "Format",
                value: photo.livePhotoVideoAssetName != nil ? "Live Photo" : "Still Photo"
            )
            #endif
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func metadataPill(title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.white.opacity(0.08), in: Capsule())
    }

    private func metadataDetailRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func loadLocationName() async {
        guard let currentPhoto else { return }
        guard currentPhoto.latitude != 0 || currentPhoto.longitude != 0 else {
            await MainActor.run {
                locationName = "No location"
            }
            return
        }

        if let storedLocationName = currentPhoto.locationName, !storedLocationName.isEmpty {
            await MainActor.run {
                locationName = storedLocationName
            }
            await LocationNameCacheService.shared.setCachedName(
                storedLocationName,
                for: currentPhoto.latitude,
                longitude: currentPhoto.longitude
            )
            return
        }

        if let cachedLocationName = await LocationNameCacheService.shared.cachedName(
            for: currentPhoto.latitude,
            longitude: currentPhoto.longitude
        ) {
            await MainActor.run {
                locationName = cachedLocationName
            }
            await persistResolvedLocationName(cachedLocationName, for: currentPhoto)
            return
        }

        let location = CLLocation(latitude: currentPhoto.latitude, longitude: currentPhoto.longitude)

        do {
            guard let request = MKReverseGeocodingRequest(location: location) else {
                await MainActor.run {
                    locationName = "Pinned location"
                }
                await persistResolvedLocationName("Pinned location", for: currentPhoto)
                return
            }

            let mapItems = try await request.mapItems
            let mapItem = mapItems.first

            let resolvedName =
                mapItem?.addressRepresentations?.cityWithContext(.short) ??
                mapItem?.addressRepresentations?.cityName ??
                mapItem?.name ??
                "Pinned location"

            await MainActor.run {
                locationName = resolvedName
            }
            await LocationNameCacheService.shared.setCachedName(
                resolvedName,
                for: currentPhoto.latitude,
                longitude: currentPhoto.longitude
            )
            await persistResolvedLocationName(resolvedName, for: currentPhoto)
        } catch {
            await MainActor.run {
                locationName = "Pinned location"
            }
            await LocationNameCacheService.shared.setCachedName(
                "Pinned location",
                for: currentPhoto.latitude,
                longitude: currentPhoto.longitude
            )
            await persistResolvedLocationName("Pinned location", for: currentPhoto)
        }
    }

    private func persistResolvedLocationName(_ name: String, for photo: DailyPhoto) async {
        await MainActor.run {
            if photo.locationName == name { return }
            photo.locationName = name
            photo.modifiedAt = Date()
            do {
                try viewContext.save()
            } catch {
                print("Failed to persist location name: \(error.localizedDescription)")
            }
        }
    }

    private func saveToPhotosLibrary() {
        guard !isPreparingShare, let currentPhoto else { return }
        isPreparingShare = true

        Task {
            do {
                let authorizationStatus = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                guard authorizationStatus == .authorized || authorizationStatus == .limited else {
                    await MainActor.run {
                        shareStatusMessage = "Photos permission is required to save."
                        isPreparingShare = false
                    }
                    return
                }

                if let liveImageAssetName = currentPhoto.livePhotoImageAssetName,
                   let liveVideoAssetName = currentPhoto.livePhotoVideoAssetName {
                    let liveImageURL = try CloudKitService.shared.loadAssetURL(named: liveImageAssetName)
                    let liveVideoURL = try CloudKitService.shared.loadAssetURL(named: liveVideoAssetName)
                    try await saveLivePhotoToLibrary(for: currentPhoto, imageURL: liveImageURL, videoURL: liveVideoURL)
                } else if currentPhoto.fullImageAssetName != nil {
                    let stillURL = try PhotoStorageService.shared.prepareStillPhotoShareURL(for: currentPhoto)
                    try await saveStillPhotoToLibrary(for: currentPhoto, imageURL: stillURL)
                } else {
                    throw PhotoStorageError.noImageAsset
                }

                await MainActor.run {
                    shareStatusMessage = "Saved to Photos."
                    isPreparingShare = false
                }
            } catch {
                await MainActor.run {
                    shareStatusMessage = "Failed to save to Photos: \(error.localizedDescription)"
                    isPreparingShare = false
                }
            }
        }
    }

    private func shareStillPhoto() {
        guard !isPreparingShare, let currentPhoto else { return }
        isPreparingShare = true

        Task {
            do {
                let stillURL = try PhotoStorageService.shared.prepareStillPhotoShareURL(for: currentPhoto)
                let previewImage = makeSharePreviewImage(from: stillURL) ?? UIImage(data: currentPhoto.thumbnailData ?? Data())
                let shareItem = URLActivityItemSource(
                    url: stillURL,
                    title: navigationDateTitle,
                    previewImage: previewImage
                )
                await MainActor.run {
                    sharePayload = SharePayload(items: [shareItem])
                    isPreparingShare = false
                }
            } catch {
                await MainActor.run {
                    shareStatusMessage = "Failed to prepare photo share: \(error.localizedDescription)"
                    isPreparingShare = false
                }
            }
        }
    }

    private func shareLivePhotoFiles() {
        guard !isPreparingShare, let currentPhoto else { return }
        isPreparingShare = true

        Task {
            do {
                let items = try PhotoStorageService.shared.prepareLivePhotoShareItemURLs(for: currentPhoto)
                await MainActor.run {
                    sharePayload = SharePayload(items: items)
                    isPreparingShare = false
                }
            } catch {
                await MainActor.run {
                    shareStatusMessage = "No Live Photo files available for this item."
                    isPreparingShare = false
                }
            }
        }
    }

    private func saveLivePhotoToLibrary(for photo: DailyPhoto, imageURL: URL, videoURL: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.creationDate = photo.captureDate
            if photo.latitude != 0 || photo.longitude != 0 {
                request.location = CLLocation(latitude: photo.latitude, longitude: photo.longitude)
            }
            request.addResource(with: .photo, fileURL: imageURL, options: nil)
            request.addResource(with: .pairedVideo, fileURL: videoURL, options: nil)
        }
    }

    private func saveStillPhotoToLibrary(for photo: DailyPhoto, imageURL: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.creationDate = photo.captureDate
            if photo.latitude != 0 || photo.longitude != 0 {
                request.location = CLLocation(latitude: photo.latitude, longitude: photo.longitude)
            }
            request.addResource(with: .photo, fileURL: imageURL, options: nil)
        }
    }

    private func makeSharePreviewImage(from url: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 1024
        ]
        guard let cgThumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgThumbnail)
    }

    private func openLocationInMaps() {
        guard let currentPhoto else { return }
        guard currentPhoto.latitude != 0 || currentPhoto.longitude != 0 else { return }

        let coordinate = CLLocationCoordinate2D(latitude: currentPhoto.latitude, longitude: currentPhoto.longitude)
        let location = CLLocation(latitude: currentPhoto.latitude, longitude: currentPhoto.longitude)
        let mapItem = MKMapItem(location: location, address: nil)
        mapItem.name = locationName == "Unknown location" ? "Photo Location" : locationName
        mapItem.openInMaps(launchOptions: [
            MKLaunchOptionsMapCenterKey: NSValue(mkCoordinate: coordinate),
            MKLaunchOptionsMapSpanKey: NSValue(mkCoordinateSpan: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02))
        ])
    }

    private func deletePhoto() {
        guard !isDeleting, let currentPhoto else { return }

        isDeleting = true
        Task {
            do {
                try await PhotoStorageService.shared.deletePhoto(currentPhoto, context: viewContext)
                await MainActor.run {
                    isDeleting = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isDeleting = false
                }
                print("Failed to delete photo: \(error.localizedDescription)")
            }
        }
    }
}

private struct PhotoPagerPageView: View {
    let photo: DailyPhoto
    let bottomInset: CGFloat

    @State private var fullImage: UIImage?
    @State private var isLoadingImage = true
    @State private var livePhotoImageURL: URL?
    @State private var livePhotoVideoURL: URL?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack {
                Spacer(minLength: 0)

                if let fullImage = fullImage {
                    if let imageURL = livePhotoImageURL, let videoURL = livePhotoVideoURL {
                        SnapBackZoomContainer {
                            LivePhotoContainerView(
                                imageURL: imageURL,
                                videoURL: videoURL,
                                fallbackImage: fullImage
                            )
                            .aspectRatio(fullImage.size, contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .aspectRatio(fullImage.size, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                    } else {
                        SnapBackZoomContainer {
                            Image(uiImage: fullImage)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .aspectRatio(fullImage.size, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                    }
                } else if isLoadingImage {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .frame(height: 400)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, bottomInset)
        }
        .task(id: photo.objectID) {
            await loadFullImage()
            loadLivePhotoResources()
        }
    }

    private func loadFullImage() async {
        do {
            let image = try await PhotoStorageService.shared.loadFullImage(from: photo)
            await MainActor.run {
                fullImage = image
                isLoadingImage = false
            }
        } catch {
            if let thumbnailData = photo.thumbnailData,
               let thumbnail = UIImage(data: thumbnailData) {
                await MainActor.run {
                    fullImage = thumbnail
                    isLoadingImage = false
                }
            }
        }
    }

    private func loadLivePhotoResources() {
        #if targetEnvironment(simulator)
        livePhotoImageURL = nil
        livePhotoVideoURL = nil
        #else
        do {
            let resources = try PhotoStorageService.shared.loadLivePhotoResources(from: photo)
            livePhotoImageURL = resources.imageURL
            livePhotoVideoURL = resources.videoURL
        } catch {
            livePhotoImageURL = nil
            livePhotoVideoURL = nil
        }
        #endif
    }
}

#Preview {
    PhotoPagerView(
        photos: [],
        selectedIndex: .constant(0)
    )
}
