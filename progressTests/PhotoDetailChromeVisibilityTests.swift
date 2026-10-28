import Testing
import UIKit
@testable import progress

@MainActor
struct PhotoDetailChromeVisibilityTests {
    @Test("Normal chrome configuration lets pending navigation layout coalesce")
    func normalConfigurationDoesNotFlushNavigationLayout() {
        let owner = UIViewController()
        let items = [UIBarButtonItem(customView: UIButton(type: .system))]
        owner.setToolbarItems(items, animated: false)
        let navigationController = LayoutCountingNavigationController(rootViewController: owner)
        navigationController.loadViewIfNeeded()
        navigationController.setToolbarHidden(false, animated: false)
        navigationController.view.layoutIfNeeded()
        let visibility = PhotoDetailChromeVisibility()
        visibility.attach(to: navigationController, toolbarOwner: owner, toolbarItems: items)
        navigationController.view.setNeedsLayout()
        let layoutCount = navigationController.layoutCount

        visibility.setVisible(true)

        #expect(navigationController.layoutCount == layoutCount)
        #expect(owner.toolbarItems?.count == 1)
        #expect(navigationController.navigationBar.alpha == 1)
        navigationController.view.layoutIfNeeded()
        #expect(navigationController.layoutCount > layoutCount)
    }

    @Test("Immediate dismissal flushes layout even after chrome was already configured hidden")
    func dismissalFlushesPendingHiddenLayout() {
        let owner = UIViewController()
        let navigationController = LayoutCountingNavigationController(rootViewController: owner)
        let button = UIButton(type: .system)
        let items = [UIBarButtonItem(customView: button)]
        let visibility = PhotoDetailChromeVisibility()
        visibility.attach(to: navigationController, toolbarOwner: owner, toolbarItems: items)
        visibility.setVisible(false)
        navigationController.view.layoutIfNeeded()
        navigationController.view.setNeedsLayout()
        let layoutCount = navigationController.layoutCount

        visibility.hideImmediately()

        #expect(navigationController.layoutCount > layoutCount)
        #expect(owner.toolbarItems?.isEmpty == true)
        #expect(items[0].isHidden)
        #expect(button.isHidden)
        #expect(navigationController.toolbar.alpha == 0)
    }

    @Test("Dismissal removes bottom toolbar items before returning to the grid")
    func dismissalRemovesToolbarItemsImmediately() throws {
        let owner = UIViewController()
        let navigationController = UINavigationController(rootViewController: owner)
        let button = UIButton(type: .system)
        let items = [UIBarButtonItem(customView: button)]
        let visibility = PhotoDetailChromeVisibility()
        visibility.attach(to: navigationController, toolbarOwner: owner, toolbarItems: items)
        visibility.setVisible(true)
        try #require(owner.toolbarItems?.count == 1)

        visibility.hideImmediately()

        #expect(owner.toolbarItems?.isEmpty == true)
        #expect(items[0].isHidden)
        #expect(button.isHidden)
        #expect(navigationController.navigationBar.alpha == 0)
        #expect(navigationController.toolbar.alpha == 0)
        #expect(navigationController.isToolbarHidden)
        #expect(navigationController.toolbar.isUserInteractionEnabled == false)
    }

    @Test("Pending visible configurations cannot bring chrome back during dismissal")
    func staleVisibleConfigurationCannotRestoreChrome() {
        let owner = UIViewController()
        let navigationController = UINavigationController(rootViewController: owner)
        let button = UIButton(type: .system)
        let items = [UIBarButtonItem(customView: button)]
        let visibility = PhotoDetailChromeVisibility()
        visibility.attach(to: navigationController, toolbarOwner: owner, toolbarItems: items)
        visibility.setVisible(true)
        visibility.hideImmediately()

        // SwiftUI can repeat the old visible configuration during UIKit layout.
        visibility.attach(to: navigationController, toolbarOwner: owner, toolbarItems: items)
        visibility.setVisible(true)
        visibility.hideImmediately()

        #expect(owner.toolbarItems?.isEmpty == true)
        #expect(items[0].isHidden)
        #expect(button.isHidden)
        #expect(navigationController.navigationBar.alpha == 0)
        #expect(navigationController.toolbar.alpha == 0)
        #expect(navigationController.isToolbarHidden)
    }

    @Test("Canceling dismissal restores the original toolbar items and their controls")
    func canceledDismissalRestoresOriginalItems() throws {
        let owner = UIViewController()
        let navigationController = UINavigationController(rootViewController: owner)
        let shareButton = UIButton(type: .system)
        let favoriteButton = UIButton(type: .system)
        let items = [
            UIBarButtonItem(customView: shareButton),
            UIBarButtonItem(systemItem: .flexibleSpace),
            UIBarButtonItem(customView: favoriteButton)
        ]
        let visibility = PhotoDetailChromeVisibility()
        visibility.attach(to: navigationController, toolbarOwner: owner, toolbarItems: items)
        visibility.setVisible(true)
        visibility.hideImmediately()

        visibility.restore()

        let restoredItems = try #require(owner.toolbarItems)
        #expect(restoredItems.elementsEqual(items, by: { $0 === $1 }))
        #expect(restoredItems.allSatisfy { $0.isHidden == false })
        #expect(shareButton.isHidden == false)
        #expect(favoriteButton.isHidden == false)
        #expect(navigationController.navigationBar.alpha == 1)
        #expect(navigationController.toolbar.alpha == 1)
        #expect(navigationController.isToolbarHidden == false)
        #expect(navigationController.toolbar.isUserInteractionEnabled)
    }

    @Test("A changed toolbar owner stays suppressed and receives its own items on cancellation")
    func changedOwnerPreservesDismissalSuppression() throws {
        let previousOwner = UIViewController()
        let navigationController = UINavigationController(rootViewController: previousOwner)
        let previousItems = [UIBarButtonItem(customView: UIButton(type: .system))]
        let visibility = PhotoDetailChromeVisibility()
        visibility.attach(to: navigationController, toolbarOwner: previousOwner, toolbarItems: previousItems)
        visibility.setVisible(true)
        visibility.hideImmediately()

        let replacementOwner = UIViewController()
        let replacementButton = UIButton(type: .system)
        let replacementItems = [UIBarButtonItem(customView: replacementButton)]
        navigationController.setViewControllers([replacementOwner], animated: false)
        visibility.attach(to: navigationController, toolbarOwner: replacementOwner, toolbarItems: replacementItems)
        visibility.setVisible(true)

        #expect(replacementOwner.toolbarItems?.isEmpty == true)
        #expect(replacementButton.isHidden)
        visibility.restore()

        let restoredItems = try #require(replacementOwner.toolbarItems)
        #expect(restoredItems.elementsEqual(replacementItems, by: { $0 === $1 }))
        #expect(replacementButton.isHidden == false)
        #expect(previousOwner.toolbarItems?.isEmpty == true)
        #expect(previousItems[0].isHidden)
    }

    @Test("Detaching after dismissal prevents later updates from restoring discarded chrome")
    func detachDoesNotResurrectToolbar() {
        let owner = UIViewController()
        let navigationController = UINavigationController(rootViewController: owner)
        let button = UIButton(type: .system)
        let items = [UIBarButtonItem(customView: button)]
        let visibility = PhotoDetailChromeVisibility()
        visibility.attach(to: navigationController, toolbarOwner: owner, toolbarItems: items)
        visibility.setVisible(true)
        visibility.hideImmediately()

        visibility.detach()
        visibility.restore()
        visibility.setVisible(true)

        #expect(owner.toolbarItems?.isEmpty == true)
        #expect(items[0].isHidden)
        #expect(button.isHidden)
        #expect(navigationController.toolbar.alpha == 0)
        #expect(navigationController.isToolbarHidden)
    }
}

@MainActor
private final class LayoutCountingNavigationController: UINavigationController {
    private(set) var layoutCount = 0

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutCount += 1
    }
}
