import Foundation

/// Storage preference, rather than temporary connectivity, defines deletion scope.
enum PhotoDeletionMessage {
    static func scope(isLocalOnly: Bool) -> String {
        if isLocalOnly {
            return "Deletes photos from this device. Any kept iCloud copies are unchanged and return when you enable iCloud Sync again. This device deletion cannot be undone."
        }
        return "Permanently deletes photos from this device and iCloud, including other synced devices. If iCloud is unavailable, deletion syncs when it becomes available. This cannot be undone."
    }
}
