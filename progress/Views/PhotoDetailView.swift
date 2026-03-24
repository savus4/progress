import SwiftUI
import AVKit
import MapKit
import PhotosUI
import CoreData
import Photos

struct PhotoDetailView: View {
    let photo: DailyPhoto
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss
    @State private var fullImage: UIImage?
    @State private var isLoadingImage = true
    @State private var livePhotoImageURL: URL?
    @State private var livePhotoVideoURL: URL?
    @State private var isDeleting = false
    @State private var locationName = "Unknown location"
    @State private var showsMetadataPanel = false
    @State private var sharePayload: SharePayload?
    @State private var isPreparingShare = false
    @State private var shareStatusMessage: String?
    @State private var shareStatusToastTask: Task<Void, Never>?

    private static let navigationDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d, HH:mm")
        return formatter
    }()
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 20) {
                        // Photo display
                        if let fullImage = fullImage {
                            if let imageURL = livePhotoImageURL, let videoURL = livePhotoVideoURL {
                                LivePhotoContainerView(
                                    imageURL: imageURL,
                                    videoURL: videoURL,
                                    fallbackImage: fullImage
                                )
                                    .aspectRatio(fullImage.size, contentMode: .fit)
                            } else {
                                Image(uiImage: fullImage)
                                    .resizable()
                                    .scaledToFit()
                            }
                        } else if isLoadingImage {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .frame(height: 400)
                        }

                        if showsMetadataPanel {
                            photoMetadataPanel
                        }
                    }
                    .padding(.vertical)
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 16)
                        .onEnded { value in
                            if value.translation.height < -24 {
                                withAnimation(.easeInOut(duration: 0.22)) {
                                    showsMetadataPanel = true
                                }
                            } else if value.translation.height > 24 {
                                withAnimation(.easeInOut(duration: 0.22)) {
                                    showsMetadataPanel = false
                                }
                            }
                        }
                )
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundStyle(.white)
                }
                
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu {
                        Button(action: saveToPhotosLibrary) {
                            Label("Save Live Photo", systemImage: "square.and.arrow.down")
                        }
                        .disabled(isPreparingShare)

                        Button(action: shareStillPhoto) {
                            Label("Share Photo (HEIC)", systemImage: "photo")
                        }
                        .disabled(isPreparingShare)

                        Button(action: shareLivePhotoFiles) {
                            Label("Share Photo + Video", systemImage: "livephoto")
                        }
                        .disabled(isPreparingShare)
                    } label: {
                        if isPreparingShare {
                            ProgressView()
                        } else {
                            Image(systemName: "ellipsis.circle")
                                .foregroundStyle(.white)
                        }
                    }

                    Button(role: .destructive, action: deletePhoto) {
                        Image(systemName: "trash")
                            .foregroundStyle(.white)
                    }
                    .disabled(isDeleting)
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
        .task {
            await loadFullImage()
            loadLivePhotoResources()
            await loadLocationName()
        }
        .sheet(item: $sharePayload) { payload in
            ActivityView(activityItems: payload.items)
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
        guard let captureDate = photo.captureDate else { return "Unknown date" }
        return Self.navigationDateFormatter.string(from: captureDate)
    }

    @ViewBuilder
    private var photoMetadataPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(photo.captureDate?.formatted(date: .complete, time: .shortened) ?? "Unknown date")
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text(locationName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if photo.latitude != 0 && photo.longitude != 0 {
                Map(initialPosition: .region(MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: photo.latitude, longitude: photo.longitude),
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                ))) {
                    Marker("Photo Location", coordinate: CLLocationCoordinate2D(latitude: photo.latitude, longitude: photo.longitude))
                }
                .frame(height: 210)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }

            #if !targetEnvironment(simulator)
            if photo.livePhotoVideoAssetName != nil {
                HStack(spacing: 8) {
                    Image(systemName: "livephoto")
                        .foregroundStyle(.secondary)
                    Text("Live Photo")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            #endif
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        )
        .padding(.horizontal)
    }
    
    private func loadFullImage() async {
        do {
            let image = try await PhotoStorageService.shared.loadFullImage(from: photo)
            await MainActor.run {
                fullImage = image
                isLoadingImage = false
            }
        } catch {
            print("Error loading full image: \(error.localizedDescription)")
            // Fallback to thumbnail
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
            // Fallback to still image only
            livePhotoImageURL = nil
            livePhotoVideoURL = nil
        }
        #endif
    }

    private func loadLocationName() async {
        guard photo.latitude != 0 || photo.longitude != 0 else {
            await MainActor.run {
                locationName = "No location"
            }
            return
        }

        if let storedLocationName = photo.locationName, !storedLocationName.isEmpty {
            await MainActor.run {
                locationName = storedLocationName
            }
            await LocationNameCacheService.shared.setCachedName(
                storedLocationName,
                for: photo.latitude,
                longitude: photo.longitude
            )
            return
        }

        if let cachedLocationName = await LocationNameCacheService.shared.cachedName(
            for: photo.latitude,
            longitude: photo.longitude
        ) {
            await MainActor.run {
                locationName = cachedLocationName
            }
            await persistResolvedLocationName(cachedLocationName)
            return
        }

        let location = CLLocation(latitude: photo.latitude, longitude: photo.longitude)

        do {
            guard let request = MKReverseGeocodingRequest(location: location) else {
                await MainActor.run {
                    locationName = "Pinned location"
                }
                await persistResolvedLocationName("Pinned location")
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
                for: photo.latitude,
                longitude: photo.longitude
            )
            await persistResolvedLocationName(resolvedName)
        } catch {
            await MainActor.run {
                locationName = "Pinned location"
            }
            await LocationNameCacheService.shared.setCachedName(
                "Pinned location",
                for: photo.latitude,
                longitude: photo.longitude
            )
            await persistResolvedLocationName("Pinned location")
        }
    }

    private func persistResolvedLocationName(_ name: String) async {
        await MainActor.run {
            if photo.locationName == name { return }
            photo.locationName = name
            photo.modifiedAt = Date()
            do {
                try viewContext.save()
            } catch {
                print("Failed to persist location name: \\(error.localizedDescription)")
            }
        }
    }
    
    private func saveToPhotosLibrary() {
        guard !isPreparingShare else { return }
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

                if let liveImageAssetName = photo.livePhotoImageAssetName,
                   let liveVideoAssetName = photo.livePhotoVideoAssetName {
                    let liveImageURL = try CloudKitService.shared.loadAssetURL(named: liveImageAssetName)
                    let liveVideoURL = try CloudKitService.shared.loadAssetURL(named: liveVideoAssetName)
                    try await saveLivePhotoToLibrary(imageURL: liveImageURL, videoURL: liveVideoURL)
                } else if let stillAssetName = photo.fullImageAssetName {
                    _ = stillAssetName
                    let stillURL = try PhotoStorageService.shared.prepareStillPhotoHEICShareURL(for: photo)
                    try await saveStillPhotoToLibrary(imageURL: stillURL)
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
        guard !isPreparingShare else { return }
        isPreparingShare = true

        Task {
            do {
                let stillData = try PhotoStorageService.shared.prepareStillPhotoHEICShareData(for: photo)
                let previewImage = fullImage ?? photo.thumbnailData.flatMap { UIImage(data: $0) }
                let shareItem = HEICDataActivityItemSource(
                    data: stillData,
                    title: navigationDateTitle,
                    previewImage: previewImage
                )
                await MainActor.run {
                    sharePayload = SharePayload(items: [shareItem])
                    isPreparingShare = false
                }
            } catch {
                await MainActor.run {
                    shareStatusMessage = "Failed to prepare HEIC share: \(error.localizedDescription)"
                    isPreparingShare = false
                }
            }
        }
    }

    private func shareLivePhotoFiles() {
        guard !isPreparingShare else { return }
        isPreparingShare = true

        Task {
            do {
                let items = try PhotoStorageService.shared.prepareLivePhotoShareItemURLs(for: photo)
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

    private func saveLivePhotoToLibrary(imageURL: URL, videoURL: URL) async throws {
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

    private func saveStillPhotoToLibrary(imageURL: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.creationDate = photo.captureDate
            if photo.latitude != 0 || photo.longitude != 0 {
                request.location = CLLocation(latitude: photo.latitude, longitude: photo.longitude)
            }
            request.addResource(with: .photo, fileURL: imageURL, options: nil)
        }
    }
    
    private func deletePhoto() {
        guard !isDeleting else { return }

        isDeleting = true
        Task {
            do {
                try await PhotoStorageService.shared.deletePhoto(photo, context: viewContext)
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

private struct ShareStatusToast: View {
    let message: String
    let isError: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? .orange : .green)
            Text(message)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }
}

private struct SharePayload: Identifiable {
    let id = UUID()
    let items: [Any]
}

struct VideoPlayerView: View {
    let videoURL: URL
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            VideoPlayer(player: AVPlayer(url: videoURL))
                .ignoresSafeArea()
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
                .onAppear {
                    // Auto-play the video
                    let player = AVPlayer(url: videoURL)
                    player.play()
                }
        }
    }
}

struct LivePhotoContainerView: UIViewRepresentable {
    let imageURL: URL
    let videoURL: URL
    let fallbackImage: UIImage

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
            livePhotoView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let longPress = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
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
        PHLivePhoto.request(withResourceFileURLs: [imageURL, videoURL], placeholderImage: nil, targetSize: .zero, contentMode: .aspectFit) { livePhoto, _ in
            DispatchQueue.main.async {
                if let livePhoto {
                    view.livePhoto = livePhoto
                    view.isHidden = false
                    fallbackImageView.isHidden = true
                    view.startPlayback(with: .hint)
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
