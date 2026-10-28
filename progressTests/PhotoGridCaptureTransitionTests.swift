import CoreData
import Foundation
import Testing
import UIKit
@testable import progress

@MainActor
struct PhotoGridCaptureTransitionTests {
    @Test("Preparing a capture brings a scrolled grid to the top and keeps it there through layout")
    func preparationResetsTheScrollPosition() throws {
        let grid = try GridHarness(photoCount: 80)
        defer { grid.cleanup() }
        let collection = grid.collectionView
        collection.setContentOffset(CGPoint(x: 0, y: 600), animated: false)
        grid.controller.view.layoutIfNeeded()
        try #require(collection.contentOffset.y > -collection.adjustedContentInset.top + 200)

        grid.update(transition: PhotoGridCaptureTransition(token: UUID()))

        #expect(abs(collection.contentOffset.y + collection.adjustedContentInset.top) < 0.5)
        collection.contentInset.top += 30
        grid.controller.view.setNeedsLayout()
        grid.controller.view.layoutIfNeeded()
        #expect(abs(collection.contentOffset.y + collection.adjustedContentInset.top) < 0.5)

        grid.update(transition: nil)
        collection.setContentOffset(CGPoint(x: 0, y: 600), animated: false)
        grid.controller.view.setNeedsLayout()
        grid.controller.view.layoutIfNeeded()
        #expect(collection.contentOffset.y > -collection.adjustedContentInset.top + 200)
    }

    @Test("The saved photo waits for the reveal, flies into an empty cell, and becomes visible at landing")
    func revealReleasesTheHeldPhotoAndReportsItsDestinationOnce() async throws {
        let grid = try GridHarness(photoCount: 12)
        defer { grid.cleanup() }
        let collection = grid.collectionView
        let originalFirstID = try #require(grid.items.first?.objectID)
        var transition = PhotoGridCaptureTransition(token: UUID())
        grid.update(transition: transition)
        let savedPhoto = try grid.makePhoto(at: Date(timeIntervalSince1970: 2_000_000_000))
        transition.photoObjectID = savedPhoto.objectID

        grid.update(items: [savedPhoto] + grid.items, transition: transition,
                    hiddenPhotoObjectID: savedPhoto.objectID)
        #expect(collection.numberOfItems(inSection: 0) == 12)
        let originalCell = try #require(collection.cellForItem(at: IndexPath(item: 0, section: 0)) as? PhotoGridCollectionViewCell)
        #expect(originalCell.representedObjectID == originalFirstID)
        #expect(grid.targets.isEmpty)

        transition.isGridRevealed = true
        grid.update(transition: transition, hiddenPhotoObjectID: savedPhoto.objectID)
        #expect(grid.targets.isEmpty, "Destination readiness must leave the synchronous view update.")
        let target = try await grid.waitForCaptureTarget()

        #expect(target.token == transition.token)
        #expect(collection.numberOfItems(inSection: 0) == 13)
        #expect(abs(collection.contentOffset.y + collection.adjustedContentInset.top) < 0.5)
        let destination = IndexPath(item: 0, section: 0)
        let attributes = try #require(collection.collectionViewLayout.layoutAttributesForItem(at: destination))
        #expect(target.frame == collection.convert(attributes.frame, to: grid.window))
        let savedCell = try #require(collection.cellForItem(at: destination) as? PhotoGridCollectionViewCell)
        #expect(savedCell.representedObjectID == savedPhoto.objectID)
        #expect(savedCell.contentView.alpha == 0)

        grid.update(transition: transition, hiddenPhotoObjectID: savedPhoto.objectID)
        grid.controller.view.setNeedsLayout()
        grid.controller.view.layoutIfNeeded()
        await nextMainQueueTurn()
        #expect(grid.targets.count == 1)

        grid.update(transition: nil)
        #expect(savedCell.contentView.alpha == 1)
        #expect(savedCell.isAccessibilityElement)
    }

    @Test("Clearing a capture before queued readiness prevents a stale target callback")
    func canceledTransitionDoesNotReportItsDestination() async throws {
        let grid = try GridHarness(photoCount: 3)
        defer { grid.cleanup() }
        let firstID = try #require(grid.items.first?.objectID)
        let transition = PhotoGridCaptureTransition(
            token: UUID(), photoObjectID: firstID, isGridRevealed: true
        )

        grid.update(transition: transition, hiddenPhotoObjectID: firstID)
        grid.update(transition: nil)
        await nextMainQueueTurn()

        #expect(grid.targets.isEmpty)
        let firstCell = try #require(grid.collectionView.cellForItem(at: IndexPath(item: 0, section: 0)))
        #expect(firstCell.contentView.alpha == 1)
    }

    private func nextMainQueueTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @MainActor
    private final class GridHarness: PhotoGridCollectionViewControllerDelegate {
        let persistence = PersistenceController(inMemory: true)
        let controller = PhotoGridCollectionViewController()
        let window: UIWindow
        let collectionView: UICollectionView
        private(set) var items: [UIKitPhotoGridItem] = []
        private(set) var targets: [(token: UUID, frame: CGRect)] = []
        private var changeToken = 0
        private var targetWaiter: CheckedContinuation<(token: UUID, frame: CGRect), any Error>?

        init(photoCount: Int) throws {
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            controller.loadViewIfNeeded()
            collectionView = try #require(controller.view.subviews.compactMap { $0 as? UICollectionView }.first)
            window.addSubview(controller.view)
            controller.view.frame = window.bounds
            controller.delegate = self
            let context = persistence.container.viewContext
            let photos = (0..<photoCount).map { index in
                let photo = DailyPhoto(context: context)
                photo.id = UUID()
                photo.captureDate = Date(timeIntervalSince1970: 1_000_000_000 - Double(index))
                return photo
            }
            try context.save()
            items = photos.map(UIKitPhotoGridItem.init(photo:))
            update(transition: nil)
        }

        func makePhoto(at date: Date) throws -> UIKitPhotoGridItem {
            let context = persistence.container.viewContext
            let photo = DailyPhoto(context: context)
            photo.id = UUID()
            photo.captureDate = date
            try context.save()
            return UIKitPhotoGridItem(photo: photo)
        }

        func update(items newItems: [UIKitPhotoGridItem]? = nil,
                    transition: PhotoGridCaptureTransition?,
                    hiddenPhotoObjectID: NSManagedObjectID? = nil) {
            if let newItems {
                items = newItems
                changeToken += 1
            }
            controller.update(
                items: items,
                changeToken: changeToken,
                centeringRequest: nil,
                captureTransition: transition,
                showsUploadStatus: false,
                isSelectionMode: false,
                selectedPhotoIDs: [],
                hiddenPhotoObjectID: hiddenPhotoObjectID
            )
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
        }

        func waitForCaptureTarget() async throws -> (token: UUID, frame: CGRect) {
            if let target = targets.last { return target }
            return try await withCheckedThrowingContinuation { continuation in
                targetWaiter = continuation
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self, let waiter = self.targetWaiter else { return }
                    self.targetWaiter = nil
                    waiter.resume(throwing: TargetReadinessError.timedOut)
                }
            }
        }

        func cleanup() {
            controller.delegate = nil
            controller.view.removeFromSuperview()
            controller.viewDidDisappear(false)
        }

        func photoGridController(_ controller: PhotoGridCollectionViewController, didPrepareCaptureTargetFor token: UUID, frame: CGRect) {
            let target = (token: token, frame: frame)
            targets.append(target)
            let waiter = targetWaiter
            targetWaiter = nil
            waiter?.resume(returning: target)
        }

        func photoGridController(_ controller: PhotoGridCollectionViewController, didOpenPhotoWith objectID: NSManagedObjectID, at index: Int, source: PhotoDetailOpeningSource) {}
        func photoGridController(_ controller: PhotoGridCollectionViewController, didUpdatePhotoFrameFor objectID: NSManagedObjectID, frame: CGRect) {}
        func photoGridController(_ controller: PhotoGridCollectionViewController, didCenterPhotoWith objectID: NSManagedObjectID, frame: CGRect) {}
        func photoGridController(_ controller: PhotoGridCollectionViewController, didUpdateSelection selectedPhotoIDs: Set<NSManagedObjectID>) {}
        func photoGridController(_ controller: PhotoGridCollectionViewController, didUpdateTopVisibleDate date: Date?) {}
        func photoGridController(_ controller: PhotoGridCollectionViewController, didUpdateFirstItemFrame frame: CGRect) {}
        func photoGridController(_ controller: PhotoGridCollectionViewController, didChangeScrollActivity isActive: Bool) {}
        func photoGridController(_ controller: PhotoGridCollectionViewController, didRequestContextAction action: PhotoGridContextAction, for objectID: NSManagedObjectID) {}
    }

    private enum TargetReadinessError: Error {
        case timedOut
    }
}
