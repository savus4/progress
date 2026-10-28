import SwiftUI
import UIKit

/// A horizontal pan with exactly two fingers, leaving one-finger grid scrolling alone.
struct TimelineSwipeGesture: UIGestureRecognizerRepresentable {
    var isEnabled: Bool
    var onBegan: () -> Void
    var onSwipe: (Direction) -> Void

    enum Direction {
        case left
        case right

        func destinationID(in ids: [UUID], selectedID: UUID, layoutDirection: LayoutDirection) -> UUID? {
            guard let index = ids.firstIndex(of: selectedID) else { return nil }
            let movesForward = (self == .left) == (layoutDirection == .leftToRight)
            let destination = index + (movesForward ? 1 : -1)
            return ids.indices.contains(destination) ? ids[destination] : nil
        }
    }

    // Identifies this pan to the grid's pinch delegate so zooming and switching stay exclusive.
    final class Recognizer: UIPanGestureRecognizer {}

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> Recognizer {
        let recognizer = Recognizer()
        recognizer.minimumNumberOfTouches = 2
        recognizer.maximumNumberOfTouches = 2
        recognizer.cancelsTouchesInView = true
        recognizer.delegate = context.coordinator
        recognizer.isEnabled = isEnabled
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: Recognizer, context: Context) {
        recognizer.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: Recognizer, context: Context) {
        guard isEnabled else { return }
        switch recognizer.state {
        case .began:
            onBegan()
        case .ended:
            if let direction = Self.direction(
                translation: recognizer.translation(in: recognizer.view),
                velocity: recognizer.velocity(in: recognizer.view)
            ) {
                onSwipe(direction)
            }
        default:
            break
        }
    }

    static func direction(translation: CGPoint, velocity: CGPoint) -> Direction? {
        guard abs(translation.x) > abs(translation.y) * 1.5 else { return nil }
        let isDeliberateDrag = abs(translation.x) >= 64
        let isQuickFlick = abs(translation.x) >= 24 && abs(velocity.x) >= 650
            && translation.x * velocity.x > 0
        guard isDeliberateDrag || isQuickFlick else { return nil }
        return translation.x < 0 ? .left : .right
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) * 1.5
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // The collection view may begin its scroll pan first; it must not swallow this swipe.
            guard let scrollView = otherGestureRecognizer.view as? UIScrollView else { return false }
            return otherGestureRecognizer === scrollView.panGestureRecognizer
        }
    }
}
