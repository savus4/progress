import UIKit

@MainActor
final class PhotoDetailChromeVisibility {
    private weak var navigationController: UINavigationController?
    private weak var toolbarOwner: UIViewController?
    private var toolbarItems: [UIBarButtonItem] = []
    private var desiredVisibility: Bool?
    private var appliedVisibility: Bool?
    private var isSuppressedForDismissal = false

    func attach(
        to navigationController: UINavigationController,
        toolbarOwner: UIViewController,
        toolbarItems: [UIBarButtonItem]
    ) {
        let hasChangedController = self.navigationController !== navigationController
            || self.toolbarOwner !== toolbarOwner
        let hasChangedItems = !self.toolbarItems.elementsEqual(toolbarItems, by: { $0 === $1 })
        guard hasChangedController || hasChangedItems else { return }
        removeBarAnimations()
        self.navigationController = navigationController
        self.toolbarOwner = toolbarOwner
        self.toolbarItems = toolbarItems
        if hasChangedController {
            desiredVisibility = nil
        }
        appliedVisibility = nil
    }

    func setVisible(_ isVisible: Bool) {
        desiredVisibility = isVisible
        applyVisibility()
    }

    private func applyVisibility() {
        let isVisible = desiredVisibility == true && !isSuppressedForDismissal
        guard let navigationController, let toolbarOwner,
              appliedVisibility != isVisible else { return }
        appliedVisibility = isVisible
        removeBarAnimations()

        UIView.performWithoutAnimation {
            // Hide controls before removing their items so floating glass groups
            // cannot outlive the bars while UIKit updates its toolbar layout.
            for item in toolbarItems {
                item.isHidden = !isVisible
                item.customView?.isHidden = !isVisible
            }
            toolbarOwner.setToolbarItems(isVisible ? toolbarItems : [], animated: false)
            navigationController.navigationBar.isUserInteractionEnabled = isVisible
            navigationController.toolbar.isUserInteractionEnabled = isVisible
            navigationController.navigationBar.alpha = isVisible ? 1 : 0
            navigationController.toolbar.alpha = isVisible ? 1 : 0
            navigationController.setToolbarHidden(!isVisible, animated: false)
        }
    }

    func hideImmediately() {
        // Layout may reapply the previous SwiftUI configuration during this call.
        isSuppressedForDismissal = true
        applyVisibility()
        // Flush dismissal cleanup before the grid appears, even if a pending
        // SwiftUI update already applied the hidden configuration. Opening and
        // restoration can share UIKit's normal layout pass instead.
        UIView.performWithoutAnimation {
            navigationController?.view.layoutIfNeeded()
        }
    }

    func restore() {
        isSuppressedForDismissal = false
        applyVisibility()
    }

    func detach() {
        removeBarAnimations()
        navigationController = nil
        toolbarOwner = nil
        toolbarItems = []
        desiredVisibility = nil
        appliedVisibility = nil
        isSuppressedForDismissal = false
    }

    private func removeBarAnimations() {
        navigationController?.navigationBar.layer.removeAllAnimations()
        navigationController?.toolbar.layer.removeAllAnimations()
    }
}
