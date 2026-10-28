import SwiftUI
import UIKit

@MainActor
struct PhotoDetailNativeOpeningView: UIViewControllerRepresentable {
    let image: UIImage
    let sourceFrame: CGRect
    let destinationFrame: CGRect
    let onStart: () -> Void
    let onComplete: () -> Void

    func makeUIViewController(context: Context) -> Controller {
        Controller(
            image: image,
            sourceFrame: sourceFrame,
            destinationFrame: destinationFrame,
            onStart: onStart,
            onComplete: onComplete
        )
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.update(
            image: image,
            sourceFrame: sourceFrame,
            destinationFrame: destinationFrame,
            onStart: onStart,
            onComplete: onComplete
        )
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.cancel()
    }

    @MainActor
    final class Controller: UIViewController {
        private static let duration = 0.28
        private static let photoAnimationKey = "photoOpening"
        private static let backdropAnimationKey = "photoOpeningBackdrop"

        private let backdrop = UIView()
        private let imageView = UIImageView()
        private var image: UIImage
        private var sourceFrame: CGRect
        private var destinationFrame: CGRect
        private var onStart: (() -> Void)?
        private var onComplete: (() -> Void)?
        private var hasAppeared = false
        private var hasStarted = false
        private var hasCompleted = false
        private var isCancelled = false
        private lazy var animationDelegate = CompletionDelegate(controller: self)

        init(
            image: UIImage,
            sourceFrame: CGRect,
            destinationFrame: CGRect,
            onStart: @escaping () -> Void,
            onComplete: @escaping () -> Void
        ) {
            self.image = image
            self.sourceFrame = sourceFrame
            self.destinationFrame = destinationFrame
            self.onStart = onStart
            self.onComplete = onComplete
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func loadView() {
            let container = UIView()
            container.backgroundColor = .clear
            container.isOpaque = false
            container.isUserInteractionEnabled = false
            container.accessibilityElementsHidden = true

            backdrop.backgroundColor = .black
            backdrop.alpha = 0
            backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(backdrop)

            imageView.image = image
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.frame = sourceFrame
            container.addSubview(imageView)
            view = container
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            hasAppeared = true
            startIfReady()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            backdrop.frame = view.bounds
            startIfReady()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            hasAppeared = false
            cancel()
        }

        func update(
            image: UIImage,
            sourceFrame: CGRect,
            destinationFrame: CGRect,
            onStart: @escaping () -> Void,
            onComplete: @escaping () -> Void
        ) {
            guard !isCancelled, !hasCompleted else { return }
            self.onStart = onStart
            self.onComplete = onComplete
            guard !hasStarted else { return }
            if self.image !== image {
                self.image = image
                imageView.image = image
            }
            self.sourceFrame = sourceFrame
            self.destinationFrame = destinationFrame
            imageView.frame = sourceFrame
            startIfReady()
        }

        func cancel() {
            // Invalidate callbacks before removing animations, which calls delegates.
            isCancelled = true
            onStart = nil
            onComplete = nil
            imageView.layer.removeAnimation(forKey: Self.photoAnimationKey)
            backdrop.layer.removeAnimation(forKey: Self.backdropAnimationKey)
        }

        private func startIfReady() {
            guard hasAppeared, !hasStarted, !isCancelled,
                  let window = viewIfLoaded?.window,
                  view.bounds.width > 0, view.bounds.height > 0 else { return }
            hasStarted = true
            let start = onStart
            onStart = nil
            start?()
            guard !isCancelled else { return }

            guard sourceFrame.width > 0, sourceFrame.height > 0,
                  destinationFrame.width > 0, destinationFrame.height > 0 else {
                backdrop.alpha = 1
                finish()
                return
            }

            let maximumRate = Float(min(window.windowScene?.screen.maximumFramesPerSecond ?? 60, 120))
            let frameRateRange = CAFrameRateRange(
                minimum: min(80, maximumRate),
                maximum: maximumRate,
                preferred: maximumRate
            )
            let timing = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            let bounds = CABasicAnimation(keyPath: "bounds")
            bounds.fromValue = NSValue(cgRect: CGRect(origin: .zero, size: sourceFrame.size))
            bounds.toValue = NSValue(cgRect: CGRect(origin: .zero, size: destinationFrame.size))
            bounds.duration = Self.duration
            bounds.preferredFrameRateRange = frameRateRange

            let position = CABasicAnimation(keyPath: "position")
            position.fromValue = NSValue(cgPoint: CGPoint(x: sourceFrame.midX, y: sourceFrame.midY))
            position.toValue = NSValue(cgPoint: CGPoint(x: destinationFrame.midX, y: destinationFrame.midY))
            position.duration = Self.duration
            position.preferredFrameRateRange = frameRateRange

            let photo = CAAnimationGroup()
            photo.animations = [bounds, position]
            photo.duration = Self.duration
            photo.timingFunction = timing
            photo.preferredFrameRateRange = frameRateRange
            photo.delegate = animationDelegate

            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = Self.duration
            fade.timingFunction = timing
            fade.preferredFrameRateRange = frameRateRange

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            imageView.bounds = CGRect(origin: .zero, size: destinationFrame.size)
            imageView.center = CGPoint(x: destinationFrame.midX, y: destinationFrame.midY)
            backdrop.alpha = 1
            // Explicit source values survive an initial insertion and final model
            // update sharing the same transaction, without a display-link barrier.
            imageView.layer.add(photo, forKey: Self.photoAnimationKey)
            backdrop.layer.add(fade, forKey: Self.backdropAnimationKey)
            CATransaction.commit()
        }

        private func finish() {
            guard hasStarted, !hasCompleted, !isCancelled else { return }
            hasCompleted = true
            let completion = onComplete
            onComplete = nil
            completion?()
        }

        @MainActor
        private final class CompletionDelegate: NSObject, CAAnimationDelegate {
            private weak var controller: Controller?

            init(controller: Controller) {
                self.controller = controller
            }

            nonisolated func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
                guard flag else { return }
                Task { @MainActor [weak self] in
                    self?.controller?.finish()
                }
            }
        }
    }
}
