import UIKit

/// A toolbar control whose size does not depend on UIKit's bar-button wrapper.
final class PhotoDetailToolbarButton: UIButton {
    override var intrinsicContentSize: CGSize {
        CGSize(width: 44, height: 44)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        intrinsicContentSize
    }
}
