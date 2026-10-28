import CoreGraphics
import Testing
@testable import progress

struct PhotoDetailDismissalGeometryTests {
    @Test("The floating photo starts at the displayed image's aspect-fit frame")
    func startsAtAspectFitFrame() {
        let frame = PhotoDetailDismissalGeometry.draggedFrame(
            imageSize: CGSize(width: 1_200, height: 600),
            viewportSize: CGSize(width: 400, height: 800),
            translation: .zero,
            reduceMotion: false
        )

        #expect(abs(frame.minX) < 0.001)
        #expect(abs(frame.minY - 300) < 0.001)
        #expect(abs(frame.width - 400) < 0.001)
        #expect(abs(frame.height - 200) < 0.001)
    }

    @Test("Dragging down shrinks the photo while its center follows both finger axes")
    func tracksBothAxesWhileShrinking() {
        let frame = PhotoDetailDismissalGeometry.draggedFrame(
            imageSize: CGSize(width: 1_200, height: 600),
            viewportSize: CGSize(width: 400, height: 800),
            translation: CGSize(width: -60, height: 180),
            reduceMotion: false
        )

        #expect(abs(frame.midX - 140) < 0.001)
        #expect(abs(frame.midY - 580) < 0.001)
        #expect(abs(frame.width - 300) < 0.001)
        #expect(abs(frame.height - 150) < 0.001)
    }

    @Test("Long drags keep a visible photo and preserve its aspect ratio")
    func longDragHasMinimumSize() {
        let frame = PhotoDetailDismissalGeometry.draggedFrame(
            imageSize: CGSize(width: 1_200, height: 600),
            viewportSize: CGSize(width: 400, height: 800),
            translation: CGSize(width: 300, height: 8_000),
            reduceMotion: false
        )

        #expect(abs(frame.width - 220) < 0.001)
        #expect(abs(frame.height - 110) < 0.001)
        #expect(abs(frame.midX - 500) < 0.001)
    }

    @Test("Reduce Motion keeps the photo still during dismissal")
    func reducedMotionKeepsTheOriginalFrame() {
        let imageSize = CGSize(width: 600, height: 1_200)
        let viewportSize = CGSize(width: 400, height: 800)
        let initialFrame = PhotoDetailDismissalGeometry.draggedFrame(
            imageSize: imageSize, viewportSize: viewportSize,
            translation: .zero, reduceMotion: true
        )
        let draggedFrame = PhotoDetailDismissalGeometry.draggedFrame(
            imageSize: imageSize, viewportSize: viewportSize,
            translation: CGSize(width: -150, height: 300), reduceMotion: true
        )

        #expect(draggedFrame == initialFrame)
    }
}
