import CoreData
import Testing
import UIKit
@testable import progress

@MainActor
struct PhotoDetailPagingTests {
    @Test("Deletion keeps the displayed neighbor when selection is rebased after removing the photo",
          arguments: [0, 1, 2, 4])
    func deletionKeepsVisibleNeighbor(deletedIndex: Int) throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let photos = (0..<5).map { index in
            let photo = DailyPhoto(context: context)
            photo.id = UUID()
            photo.captureDate = Date(timeIntervalSince1970: Double(index) * 86_400)
            return photo
        }
        try context.save()
        let items = photos.map(PhotoDetailItem.init(photo:))
        let targetIndex = deletedIndex + 1 < items.count ? deletedIndex + 1 : deletedIndex - 1
        let resultIndex = deletedIndex + 1 < items.count ? deletedIndex : targetIndex
        let expectedObjectID = items[targetIndex].objectID
        let transition = PhotoDetailDeleteTransition(
            deletedObjectID: items[deletedIndex].objectID,
            deletedIndex: deletedIndex,
            targetIndexBeforeRemoval: targetIndex,
            resultIndexAfterRemoval: resultIndex
        )
        let controller = PhotoDetailPagingViewController(
            items: items, initialIndex: deletedIndex, isOpening: true, onIndexChanged: { _ in }
        )
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        controller.view.layoutIfNeeded()
        let collection = try #require(controller.view.subviews.compactMap { $0 as? UICollectionView }.first)
        let pageWidth = collection.bounds.width
        try #require(pageWidth > 0)

        var completedTransition: PhotoDetailDeleteTransition?
        controller.onDeleteTransitionCompleted = { completedTransition = $0 }
        controller.performDeleteTransitionIfNeeded(transition, items: items, currentIndex: deletedIndex)
        // Finish paging synchronously; storage is allowed to complete after this point.
        collection.setContentOffset(CGPoint(x: CGFloat(targetIndex) * pageWidth, y: 0), animated: false)
        controller.scrollViewDidEndScrollingAnimation(collection)
        try #require(completedTransition?.id == transition.id)

        let remainingItems = items.filter { $0.objectID != transition.deletedObjectID }
        // Exercise separate item and selection updates from the SwiftUI bridge.
        controller.resetDeleteTransitionIfNeeded()
        controller.updateItems(remainingItems, currentIndex: targetIndex)
        controller.view.layoutIfNeeded()
        controller.updateItems(remainingItems, currentIndex: resultIndex)
        controller.view.layoutIfNeeded()

        let visibleIndex = Int((collection.contentOffset.x / pageWidth).rounded())
        #expect(visibleIndex == resultIndex)
        let visibleItem = try #require(remainingItems.indices.contains(visibleIndex) ? remainingItems[visibleIndex] : nil)
        #expect(visibleItem.objectID == expectedObjectID)
        #expect(collection.numberOfItems(inSection: 0) == items.count - 1)
    }
}
