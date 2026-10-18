import CoreData
import Foundation

@MainActor
enum PhotoVideoVisibility {
    static func shouldHide(_ photos: [DailyPhoto]) -> Bool {
        photos.contains { !$0.isHiddenFromVideo }
    }

    static func setHidden(_ isHidden: Bool, for photos: [DailyPhoto], in context: NSManagedObjectContext) throws {
        let changedPhotos = photos.filter {
            $0.isHiddenFromVideo != isHidden || (isHidden && ($0.isHearted || $0.isFavoriteLivePhoto))
        }
        guard !changedPhotos.isEmpty else { return }

        let now = Date()
        do {
            for photo in changedPhotos {
                photo.isHiddenFromVideo = isHidden
                if isHidden {
                    photo.isHearted = false
                    photo.isFavoriteLivePhoto = false
                }
                photo.modifiedAt = now
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}
