import SwiftUI
import Testing
import UIKit
@testable import progress

@MainActor
struct TimelineSwipeGestureTests {
    @Test("Deliberate horizontal drags and short flicks switch in their travel direction")
    func horizontalSwipes() {
        #expect(TimelineSwipeGesture.direction(translation: CGPoint(x: -100, y: 8), velocity: .zero) == .left)
        #expect(TimelineSwipeGesture.direction(translation: CGPoint(x: 100, y: -8), velocity: .zero) == .right)
        #expect(TimelineSwipeGesture.direction(
            translation: CGPoint(x: -30, y: 2), velocity: CGPoint(x: -800, y: 0)
        ) == .left)
    }

    @Test("Vertical scrolling, diagonal movement, tiny drags, and cancelled flicks do not switch")
    func incidentalMovement() {
        #expect(TimelineSwipeGesture.direction(translation: CGPoint(x: 10, y: 150), velocity: .zero) == nil)
        #expect(TimelineSwipeGesture.direction(translation: CGPoint(x: 100, y: 100), velocity: .zero) == nil)
        #expect(TimelineSwipeGesture.direction(translation: CGPoint(x: 40, y: 0), velocity: .zero) == nil)
        #expect(TimelineSwipeGesture.direction(
            translation: CGPoint(x: 5, y: 0), velocity: CGPoint(x: 1_000, y: 0)
        ) == nil)
        #expect(TimelineSwipeGesture.direction(
            translation: CGPoint(x: -30, y: 0), velocity: CGPoint(x: 800, y: 0)
        ) == nil)
    }

    @Test("Swipes follow settings order, stop at either end, and support right-to-left layouts")
    func timelineDestinations() {
        let ids = [UUID(), UUID(), UUID()]
        typealias Direction = TimelineSwipeGesture.Direction
        #expect(Direction.left.destinationID(in: ids, selectedID: ids[0], layoutDirection: .leftToRight) == ids[1])
        #expect(Direction.right.destinationID(in: ids, selectedID: ids[1], layoutDirection: .leftToRight) == ids[0])
        #expect(Direction.right.destinationID(in: ids, selectedID: ids[0], layoutDirection: .leftToRight) == nil)
        #expect(Direction.left.destinationID(in: ids, selectedID: ids[2], layoutDirection: .leftToRight) == nil)
        #expect(Direction.left.destinationID(in: ids, selectedID: ids[1], layoutDirection: .rightToLeft) == ids[0])
        #expect(Direction.right.destinationID(in: ids, selectedID: ids[0], layoutDirection: .rightToLeft) == ids[1])
        #expect(Direction.left.destinationID(in: [ids[0]], selectedID: ids[0], layoutDirection: .leftToRight) == nil)
        #expect(Direction.left.destinationID(in: ids, selectedID: UUID(), layoutDirection: .leftToRight) == nil)
    }

    @Test("The scroll pan can coexist with switching, while grid pinch zoom remains exclusive")
    func gestureCoordination() throws {
        let coordinator = TimelineSwipeGesture.Coordinator()
        let swipe = TimelineSwipeGesture.Recognizer()
        let grid = PhotoGridCollectionViewController()
        grid.loadViewIfNeeded()
        let scrollView = try #require(grid.view.subviews.compactMap { $0 as? UICollectionView }.first)
        let pinch = try #require(scrollView.gestureRecognizers?.compactMap { $0 as? UIPinchGestureRecognizer }.first)

        #expect(coordinator.gestureRecognizer(swipe, shouldRecognizeSimultaneouslyWith: scrollView.panGestureRecognizer))
        #expect(coordinator.gestureRecognizer(swipe, shouldRecognizeSimultaneouslyWith: pinch) == false)
        #expect(grid.gestureRecognizer(pinch, shouldRecognizeSimultaneouslyWith: swipe) == false)
    }
}
