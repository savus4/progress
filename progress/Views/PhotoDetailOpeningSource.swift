import UIKit

struct PhotoDetailOpeningSource {
    let frameInGlobal: CGRect
    let image: UIImage?

    var canExpand: Bool {
        frameInGlobal.width > 0 && frameInGlobal.height > 0
            && image != nil
    }
}
