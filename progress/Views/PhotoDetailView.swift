import SwiftUI
import AVKit
import Photos
import PhotosUI

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
        return scrollView
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        context.coordinator.hostingController.rootView = AnyView(content)
        context.coordinator.hostingController.view.frame = uiView.bounds
        if uiView.zoomScale < 1.001 {
            uiView.contentSize = uiView.bounds.size
            context.coordinator.centerContent(in: uiView)
        }
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
    }
}

struct ShareStatusToast: View {
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

struct SharePayload: Identifiable {
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

extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}
