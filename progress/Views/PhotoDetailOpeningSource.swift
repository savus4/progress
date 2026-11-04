import UIKit

struct PhotoDetailOpeningSource {
    let frameInGlobal: CGRect
    let image: UIImage?
    var isMirrored = false

    var canExpand: Bool {
        frameInGlobal.width > 0 && frameInGlobal.height > 0
            && image != nil
    }
}
