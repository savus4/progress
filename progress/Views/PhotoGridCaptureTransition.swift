import CoreData
import Foundation

struct PhotoGridCaptureTransition: Equatable {
    let token: UUID
    var photoObjectID: NSManagedObjectID? = nil
    var isGridRevealed = false
}
