import CoreData
import Combine
import Foundation

struct LegacyPayloadMigrationResult: Sendable {
    let scannedCount: Int
    let migratedCount: Int
    let missingAssetCount: Int
    let failedCount: Int
}

@MainActor
final class CloudSyncMonitor: ObservableObject {
    static let shared = CloudSyncMonitor()

    enum SyncState: Equatable {
        case idle
        case syncing(NSPersistentCloudKitContainer.EventType)
        case failed(String)
    }

    @Published private(set) var syncState: SyncState = .idle
    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var pendingMigrationCount = 0
    @Published private(set) var isRunningMigration = false
    @Published private(set) var lastMigrationResult: LegacyPayloadMigrationResult?
    @Published private(set) var lastMigrationError: String?
    @Published private(set) var pendingUploadCount = 0
    @Published private(set) var failedUploadCount = 0
    @Published private(set) var pausedUploadCount = 0
    @Published private(set) var uploadingAssetCount = 0
    @Published private(set) var downloadingAssetCount = 0
    @Published private(set) var isUploadProcessorActive = false

    private var observer: NSObjectProtocol?
    private var uploadObserver: NSObjectProtocol?
    private var uploadProcessingObserver: NSObjectProtocol?
    private var contextSaveObserver: NSObjectProtocol?
    private var assetTransferObserver: NSObjectProtocol?
    private var activeDownloadAssetNames: Set<String> = []

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event else {
                return
            }
            Task { @MainActor [weak self] in
                self?.handle(event: event)
            }
        }

        uploadObserver = NotificationCenter.default.addObserver(
            forName: PhotoUploadService.didCompleteUploadNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshUploadStatus()
            }
        }

        uploadProcessingObserver = NotificationCenter.default.addObserver(
            forName: PhotoUploadService.processingStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let isProcessing = notification.userInfo?["isProcessing"] as? Bool else {
                return
            }

            Task { @MainActor [weak self] in
                self?.isUploadProcessorActive = isProcessing
            }
        }

        contextSaveObserver = NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextDidSave,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshUploadStatus()
            }
        }

        assetTransferObserver = NotificationCenter.default.addObserver(
            forName: CloudKitService.assetTransferDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let kindRawValue = notification.userInfo?["kind"] as? String,
                  let phaseRawValue = notification.userInfo?["phase"] as? String,
                  let assetName = notification.userInfo?["assetName"] as? String,
                  let kind = CloudKitService.AssetTransferKind(rawValue: kindRawValue),
                  let phase = CloudKitService.AssetTransferPhase(rawValue: phaseRawValue) else {
                return
            }

            Task { @MainActor [weak self] in
                self?.handleAssetTransfer(kind: kind, phase: phase, assetName: assetName)
            }
        }

        Task { @MainActor [weak self] in
            await self?.refreshUploadStatus()
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        if let uploadObserver {
            NotificationCenter.default.removeObserver(uploadObserver)
        }
        if let uploadProcessingObserver {
            NotificationCenter.default.removeObserver(uploadProcessingObserver)
        }
        if let contextSaveObserver {
            NotificationCenter.default.removeObserver(contextSaveObserver)
        }
        if let assetTransferObserver {
            NotificationCenter.default.removeObserver(assetTransferObserver)
        }
    }

    var statusSymbolName: String {
        if downloadingAssetCount > 0 {
            return "arrow.down.circle.icloud"
        }
        if pausedUploadCount > 0 {
            return "exclamationmark.icloud"
        }
        if uploadingAssetCount > 0 || pendingUploadCount > 0 || failedUploadCount > 0 {
            return "arrow.triangle.2.circlepath.icloud"
        }

        switch syncState {
        case .idle:
            return isRunningMigration ? "arrow.triangle.2.circlepath" : "checkmark.icloud"
        case .syncing:
            return "arrow.triangle.2.circlepath.icloud"
        case .failed:
            return "exclamationmark.icloud"
        }
    }

    var isFailing: Bool {
        if pausedUploadCount > 0 {
            return true
        }
        if case .failed = syncState {
            return true
        }
        return false
    }

    var retryableUploadCount: Int {
        failedUploadCount + pausedUploadCount
    }

    var hasRetryableUploads: Bool {
        retryableUploadCount > 0
    }

    var automaticOutstandingUploadCount: Int {
        pendingUploadCount + uploadingAssetCount + failedUploadCount
    }

    var statusTitle: String {
        if isRunningMigration {
            return "Preparing older photos for iCloud sync"
        }

        if downloadingAssetCount > 0 {
            return "Downloading original photos from iCloud"
        }

        if pausedUploadCount > 0 {
            return "Some photo uploads are paused"
        }

        if automaticOutstandingUploadCount > 0 {
            if uploadingAssetCount > 0 || isUploadProcessorActive {
                return automaticOutstandingUploadCount == 1
                    ? "Uploading 1 original photo to iCloud"
                    : "Uploading \(automaticOutstandingUploadCount) original photos to iCloud"
            }

            if pendingUploadCount > 0 {
                return automaticOutstandingUploadCount == 1
                    ? "Waiting to upload 1 original photo"
                    : "Waiting to upload \(automaticOutstandingUploadCount) original photos"
            }

            return automaticOutstandingUploadCount == 1
                ? "1 photo upload will retry automatically"
                : "\(automaticOutstandingUploadCount) photo uploads will retry automatically"
        }

        switch syncState {
        case .idle:
            return "iCloud sync is ready"
        case .syncing(let eventType):
            switch eventType {
            case .setup:
                return "Setting up iCloud sync"
            case .import:
                return "Downloading changes from iCloud"
            case .export:
                return "Uploading changes to iCloud"
            @unknown default:
                return "Syncing with iCloud"
            }
        case .failed:
            return "iCloud sync needs attention"
        }
    }

    var statusDetail: String {
        if isRunningMigration {
            return pendingMigrationCount > 0
                ? "\(pendingMigrationCount) older photo\(pendingMigrationCount == 1 ? "" : "s") left to backfill."
                : "Backfilling older photos for cross-device access."
        }

        if downloadingAssetCount > 0 {
            return "Currently downloading \(downloadingAssetCount) photo\(downloadingAssetCount == 1 ? "" : "s") from iCloud for viewing."
        }

        if pausedUploadCount > 0 {
            return "\(pausedUploadCount) photo\(pausedUploadCount == 1 ? "" : "s") need manual retry after account, quota, or asset issues are resolved."
        }

        if automaticOutstandingUploadCount > 0 {
            if uploadingAssetCount > 0 || isUploadProcessorActive {
                return automaticOutstandingUploadCount == 1
                    ? "1 photo is currently uploading in the background."
                    : "\(automaticOutstandingUploadCount) photos are still queued for upload."
            }

            if pendingUploadCount > 0 {
                return automaticOutstandingUploadCount == 1
                    ? "1 photo is waiting to upload when network and background time allow."
                    : "\(automaticOutstandingUploadCount) photos are still queued and will upload when network and background time allow."
            }

            return automaticOutstandingUploadCount == 1
                ? "1 photo will retry automatically later."
                : "\(automaticOutstandingUploadCount) photos are still in the automatic retry queue."
        }

        if let lastMigrationError {
            return lastMigrationError
        }

        switch syncState {
        case .idle:
            if pendingMigrationCount > 0 {
                return "\(pendingMigrationCount) older photo\(pendingMigrationCount == 1 ? "" : "s") still need a one-time sync backfill."
            }
            if let lastMigrationResult, lastMigrationResult.migratedCount > 0 {
                return "Backfilled \(lastMigrationResult.migratedCount) older photo\(lastMigrationResult.migratedCount == 1 ? "" : "s") for cross-device sync."
            }
            if let lastSyncDate {
                return "Last sync finished \(lastSyncDate.formatted(.relative(presentation: .named)))."
            }
            return "Photo metadata and originals can sync through iCloud."
        case .syncing:
            if let lastSyncDate {
                return "Last completed sync \(lastSyncDate.formatted(.relative(presentation: .named)))."
            }
            return "Changes usually sync automatically after saves and app launches."
        case .failed(let message):
            return message
        }
    }

    func beginMigration(totalPending: Int) {
        pendingMigrationCount = totalPending
        isRunningMigration = totalPending > 0
        lastMigrationError = nil
    }

    func updateMigrationProgress(remainingCount: Int) {
        pendingMigrationCount = max(remainingCount, 0)
    }

    func finishMigration(result: LegacyPayloadMigrationResult, remainingPendingCount: Int) {
        isRunningMigration = false
        pendingMigrationCount = max(remainingPendingCount, 0)
        lastMigrationResult = result
        if result.failedCount > 0 || result.missingAssetCount > 0 {
            lastMigrationError = "Backfill skipped \(result.missingAssetCount) missing asset\(result.missingAssetCount == 1 ? "" : "s") and hit \(result.failedCount) error\(result.failedCount == 1 ? "" : "s")."
        } else {
            lastMigrationError = nil
        }
    }

    func failMigration(message: String) {
        isRunningMigration = false
        lastMigrationError = message
    }

    func refreshUploadStatus() async {
        let context = await MainActor.run { PersistenceController.shared.makeBackgroundContext() }

        do {
            let counts = try await context.perform {
                func count(for states: [String]) throws -> Int {
                    let request = DailyPhoto.fetchRequest()
                    request.predicate = NSPredicate(format: "uploadStateRaw IN %@", states)
                    return try context.count(for: request)
                }

                let uploading = try count(for: [PhotoUploadState.uploading.rawValue])
                let pending = try count(for: [PhotoUploadState.pending.rawValue])
                let failed = try count(for: [PhotoUploadState.failed.rawValue])
                let paused = try count(for: [PhotoUploadState.paused.rawValue])
                return (pending, uploading, failed, paused)
            }

            pendingUploadCount = counts.0
            uploadingAssetCount = counts.1
            failedUploadCount = counts.2
            pausedUploadCount = counts.3
        } catch {
            pendingUploadCount = 0
            uploadingAssetCount = 0
            failedUploadCount = 0
            pausedUploadCount = 0
        }
    }

    var activeDownloadAssetNamesSnapshot: Set<String> {
        activeDownloadAssetNames
    }

    func isDownloading(assetNames: [String]) -> Bool {
        assetNames.contains { activeDownloadAssetNames.contains($0) }
    }

    func isDownloading(photo: DailyPhoto) -> Bool {
        isDownloading(assetNames: [
            photo.fullImageAssetName,
            photo.livePhotoImageAssetName,
            photo.livePhotoVideoAssetName
        ].compactMap { $0 })
    }

    private func handle(event: NSPersistentCloudKitContainer.Event) {
        if let endDate = event.endDate {
            if let error = event.error {
                syncState = .failed(error.localizedDescription)
            } else {
                syncState = .idle
                lastSyncDate = endDate
            }
        } else {
            syncState = .syncing(event.type)
        }
    }

    private func handleAssetTransfer(
        kind: CloudKitService.AssetTransferKind,
        phase: CloudKitService.AssetTransferPhase,
        assetName: String
    ) {
        guard kind == .download else { return }

        switch phase {
        case .started:
            activeDownloadAssetNames.insert(assetName)
        case .finished, .failed:
            activeDownloadAssetNames.remove(assetName)
        }

        downloadingAssetCount = activeDownloadAssetNames.count
    }
}
