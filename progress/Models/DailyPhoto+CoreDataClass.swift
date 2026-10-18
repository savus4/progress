import CoreData
import Foundation

@objc(DailyPhoto)
nonisolated final class DailyPhoto: NSManagedObject {
    override func willSave() {
        super.willSave()
        // Enforce this for every save path, including edits outside the photo menus.
        guard !isDeleted, isHiddenFromVideo else { return }
        if isHearted { isHearted = false }
        if isFavoriteLivePhoto { isFavoriteLivePhoto = false }
    }
}
