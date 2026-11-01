import CoreData
import SwiftUI

struct CameraReferencePhotoOverlay: View {
    @ObservedObject var photo: DailyPhoto
    let isMirrored: Bool

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(x: isMirrored ? -1 : 1, y: 1)
                    .opacity(0.3)
                    .accessibilityLabel("Previous photo reference")
                    .accessibilityIdentifier("experimentalCameraReferencePhotoOverlay")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .task(id: photo.fullImageAssetName) {
            await loadImage()
        }
    }

    private func loadImage() async {
        let thumbnail = await DecodedThumbnailCache.shared.image(
            for: photo.objectID, data: photo.thumbnailData, resolution: .expanded
        )
        guard !Task.isCancelled else { return }
        image = thumbnail

        // Keep the local thumbnail as a reference if the original is unavailable offline.
        if let original = try? await PhotoStorageService.shared.loadFullImage(from: photo) {
            guard !Task.isCancelled else { return }
            image = original
        }
    }
}
