import Foundation

/// Per-operation dependencies keep deletion tests isolated from the user's cloud account.
@MainActor
struct DeleteAllPhotosOperations {
    let cancelPendingUploads: () async -> Void
    let waitUntilUploadsIdle: () async -> Bool
    let isLocalModeActive: () -> Bool
    let waitForNextExportCompletion: () async -> CloudSyncMonitor.ExportWaitResult
    let deleteAssets: (Set<String>) async -> Void
    let deleteAssetsAndWaitForRemoteCleanup: (Set<String>) async -> Set<String>
}
