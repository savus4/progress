import CoreData
import Foundation

/// A camera's capabilities affect capture, never the timeline's synced choice.
enum TimelineCameraPreferences {
    static func livePhotosEnabled(for id: UUID, in timelines: TimelineSelectionStore,
                                  legacyDefaults: UserDefaults = .standard) -> Bool {
        if let preference = timelines.timelines.first(where: { $0.id == id })?.livePhotoPreference {
            return preference.isEnabled
        }
        if id == TimelineIdentity.defaultID,
           let legacy = legacyDefaults.object(forKey: CameraPreferenceKey.livePhotoCaptureEnabled) as? Bool {
            return legacy
        }
        return true
    }

    nonisolated static func capturesLivePhoto(preferred: Bool, supported: Bool) -> Bool {
        preferred && supported
    }

    static func setLivePhotosEnabled(_ enabled: Bool, for id: UUID, supported: Bool,
                                    timelines: TimelineSelectionStore, context: NSManagedObjectContext) async throws {
        guard supported else { return }
        try await timelines.setLivePhotoCaptureEnabled(enabled, for: id, in: context)
    }

    static func migrateLegacyPreference(for id: UUID, supported: Bool, timelines: TimelineSelectionStore,
                                        context: NSManagedObjectContext, legacyDefaults: UserDefaults = .standard) async throws {
        guard supported, id == TimelineIdentity.defaultID,
              !PhotoStorageModeStore.shared.mode.isMigrating,
              let legacy = legacyDefaults.object(forKey: CameraPreferenceKey.livePhotoCaptureEnabled) as? Bool else { return }
        try await TimelineStore.seedLegacyLivePhotoPreference(legacy, in: context)
        await timelines.refresh(in: context)
    }
}
