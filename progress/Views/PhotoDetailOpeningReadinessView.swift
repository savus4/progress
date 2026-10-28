import SwiftUI
import UIKit

@MainActor
struct PhotoDetailOpeningReadinessView: UIViewControllerRepresentable {
    let onReady: () -> Void

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.onReady = onReady
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.onReady = onReady
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.cancel()
    }

    @MainActor
    final class Controller: UIViewController {
        var onReady: (() -> Void)?

        private var hasAppeared = false
        private var hasDeliveredReady = false
        private var hasBeenCancelled = false
        private var hasObservedFirstFrame = false
        private var displayLink: CADisplayLink?

        override func loadView() {
            let readinessView = UIView()
            readinessView.backgroundColor = .clear
            readinessView.isOpaque = false
            readinessView.isUserInteractionEnabled = false
            readinessView.accessibilityElementsHidden = true
            view = readinessView
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            hasAppeared = true
            startIfReady()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            startIfReady()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            hasAppeared = false
            stopObservingFrames()
        }

        func cancel() {
            hasBeenCancelled = true
            onReady = nil
            stopObservingFrames()
        }

        private var isVisibleAndLaidOut: Bool {
            hasAppeared && viewIfLoaded?.window != nil
                && view.bounds.width > 0 && view.bounds.height > 0
        }

        private func startIfReady() {
            guard !hasDeliveredReady, !hasBeenCancelled,
                  displayLink == nil, isVisibleAndLaidOut else { return }

            let target = DisplayLinkTarget(controller: self)
            let link = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.displayFrame(_:)))
            displayLink = link
            link.add(to: .main, forMode: .common)
        }

        func displayFrame() {
            guard displayLink != nil, isVisibleAndLaidOut,
                  !hasDeliveredReady, !hasBeenCancelled else {
                stopObservingFrames()
                return
            }

            // Keep the source geometry unchanged across one complete display interval.
            // Yielding a task alone does not give the initial view a render opportunity.
            guard hasObservedFirstFrame else {
                hasObservedFirstFrame = true
                return
            }

            stopObservingFrames()
            hasDeliveredReady = true
            let callback = onReady
            onReady = nil
            callback?()
        }

        private func stopObservingFrames() {
            displayLink?.invalidate()
            displayLink = nil
            hasObservedFirstFrame = false
        }

        @MainActor
        private final class DisplayLinkTarget: NSObject {
            private weak var controller: Controller?

            init(controller: Controller) {
                self.controller = controller
            }

            @objc func displayFrame(_ displayLink: CADisplayLink) {
                guard let controller else {
                    displayLink.invalidate()
                    return
                }
                controller.displayFrame()
            }
        }
    }
}
