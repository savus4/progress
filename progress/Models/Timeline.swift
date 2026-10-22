import CoreData
import Foundation
import CryptoKit

/// Logical ownership stays valid when CloudKit imports photos before their metadata.
nonisolated enum TimelineIdentity {
    // Shared across devices. Never generate a new default ID at launch/migration.
    static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let defaultName = "Default"

    /// Concurrent offline deletions can remove each device's final survivor.
    /// A deterministic fresh identity restores an empty timeline, never old photos.
    static func recoveryID(afterDeleting ids: Set<UUID>) -> UUID {
        let seed = "progress.timeline.recovery." + ids.map(\.uuidString).sorted().joined(separator: ".")
        let bytes = Array(SHA256.hash(data: Data(seed.utf8)))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
                           (bytes[6] & 0x0f) | 0x50, bytes[7], (bytes[8] & 0x3f) | 0x80,
                           bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    static func photoPredicate(for timelineID: UUID) -> NSPredicate {
        let owned = NSPredicate(format: "timelineID == %@", timelineID as NSUUID)
        guard timelineID == defaultID else { return owned }
        return NSCompoundPredicate(orPredicateWithSubpredicates: [
            owned, NSPredicate(format: "timelineID == nil")
        ])
    }
}

@objc(Timeline)
nonisolated final class Timeline: NSManagedObject {
    @nonobjc class func fetchRequest() -> NSFetchRequest<Timeline> {
        NSFetchRequest<Timeline>(entityName: "Timeline")
    }

    @NSManaged var id: UUID?
    @NSManaged var name: String?
    @NSManaged var createdAt: Date?
    @NSManaged var modifiedAt: Date?
    @NSManaged var deletedAt: Date?
    /// Device-only removal; omitted when merging back into a kept iCloud library.
    @NSManaged var localDeletedAt: Date?
    @NSManaged var livePhotoCaptureEnabled: NSNumber?
    @NSManaged var livePhotoPreferenceModifiedAt: Date?

    var livePhotoPreference: TimelineLivePhotoPreference? {
        livePhotoCaptureEnabled.map {
            TimelineLivePhotoPreference(isEnabled: $0.boolValue, modifiedAt: livePhotoPreferenceModifiedAt)
        }
    }
}

nonisolated struct TimelineSnapshot: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let createdAt: Date?
    let modifiedAt: Date?
    let livePhotoPreference: TimelineLivePhotoPreference?

    init(id: UUID, name: String, createdAt: Date?, modifiedAt: Date?,
         livePhotoPreference: TimelineLivePhotoPreference? = nil) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.livePhotoPreference = livePhotoPreference
    }
}

nonisolated struct TimelineLibraryState: Sendable {
    let timelines: [TimelineSnapshot]
    let deletedIDs: Set<UUID>
}
