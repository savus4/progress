import CoreData
import Combine
import Foundation
import OSLog

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

    enum ExportWaitResult: Sendable {
        case completed
        case failed(String)
        case timedOut
    }

    private struct ExportWaiter {
        let registeredAt: Date
        let continuation: CheckedContinuation<ExportWaitResult, Never>
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
    private var exportWaiters: [UUID: ExportWaiter] = [:]
    private var uploadStatusRefreshTask: Task<Void, Never>?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "progress", category: "CloudSync")

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
                self?.scheduleUploadStatusRefresh(delay: .zero)
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
                self?.scheduleUploadStatusRefresh()
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
            self?.scheduleUploadStatusRefresh(delay: .zero)
        }
    }

    deinit {
        uploadStatusRefreshTask?.cancel()
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

    private func scheduleUploadStatusRefresh(delay: Duration = .milliseconds(250)) {
        uploadStatusRefreshTask?.cancel()
        uploadStatusRefreshTask = Task { @MainActor [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            await self?.refreshUploadStatus()
        }
    }

    func refreshUploadStatus() async {
        let context = await MainActor.run { PersistenceController.shared.makeBackgroundContext() }

        do {
            let counts = try await context.perform {
                let states = [
                    PhotoUploadState.pending.rawValue,
                    PhotoUploadState.uploading.rawValue,
                    PhotoUploadState.failed.rawValue,
                    PhotoUploadState.paused.rawValue
                ]

                let countExpression = NSExpressionDescription()
                countExpression.name = "count"
                countExpression.expression = NSExpression(
                    forFunction: "count:",
                    arguments: [NSExpression(forKeyPath: "uploadStateRaw")]
                )
                countExpression.expressionResultType = .integer64AttributeType

                let request = NSFetchRequest<NSDictionary>(entityName: "DailyPhoto")
                request.resultType = .dictionaryResultType
                request.propertiesToFetch = ["uploadStateRaw", countExpression]
                request.propertiesToGroupBy = ["uploadStateRaw"]
                request.predicate = NSPredicate(format: "uploadStateRaw IN %@", states)

                let rows = try context.fetch(request)
                var countsByState: [String: Int] = [:]

                for row in rows {
                    guard let state = row["uploadStateRaw"] as? String else { continue }
                    if let count = row["count"] as? NSNumber {
                        countsByState[state] = count.intValue
                    }
                }

                return (
                    countsByState[PhotoUploadState.pending.rawValue] ?? 0,
                    countsByState[PhotoUploadState.uploading.rawValue] ?? 0,
                    countsByState[PhotoUploadState.failed.rawValue] ?? 0,
                    countsByState[PhotoUploadState.paused.rawValue] ?? 0
                )
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

    func waitForNextExportCompletion(timeout: Duration = .seconds(30)) async -> ExportWaitResult {
        let waiterID = UUID()
        let registeredAt = Date()

        return await withCheckedContinuation { continuation in
            exportWaiters[waiterID] = ExportWaiter(
                registeredAt: registeredAt,
                continuation: continuation
            )

            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.resolveExportWaiter(id: waiterID, result: .timedOut)
            }
        }
    }

    private func handle(event: NSPersistentCloudKitContainer.Event) {
        if event.type == .export, let endDate = event.endDate {
            if let error = event.error {
                if !isSystemDeferredCloudKitError(error) {
                    resolveExportWaiters(completedAt: endDate, result: .failed(error.localizedDescription))
                }
            } else {
                resolveExportWaiters(completedAt: endDate, result: .completed)
            }
        }

        if let endDate = event.endDate {
            if let error = event.error {
                logCloudKitEventError(error, eventType: event.type)
                if isSystemDeferredCloudKitError(error) {
                    syncState = .idle
                } else {
                    syncState = .failed(error.localizedDescription)
                }
            } else {
                syncState = .idle
                lastSyncDate = endDate
            }
        } else {
            syncState = .syncing(event.type)
        }
    }

    private func isSystemDeferredCloudKitError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == 134419 {
            return true
        }

        if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isSystemDeferredCloudKitError(underlyingError)
        }

        if let detailedErrors = nsError.userInfo["NSDetailedErrors"] as? [Error] {
            return detailedErrors.contains(where: isSystemDeferredCloudKitError)
        }

        return false
    }

    private func logCloudKitEventError(_ error: Error, eventType: NSPersistentCloudKitContainer.EventType) {
        let primary = error as NSError
        let chain = describeErrorChain(primary)
        logger.error(
            """
            cloudkit-event-error type=\(String(describing: eventType), privacy: .public) \
            domain=\(primary.domain, privacy: .public) code=\(primary.code, privacy: .public) \
            description=\(primary.localizedDescription, privacy: .public) chain=\(chain, privacy: .public)
            """
        )
    }

    private func describeErrorChain(_ error: NSError) -> String {
        var fragments: [String] = []
        appendErrorDescription(error, to: &fragments, depth: 0)
        return fragments.joined(separator: " -> ")
    }

    private func appendErrorDescription(_ error: NSError, to fragments: inout [String], depth: Int) {
        guard depth < 8 else {
            fragments.append("depth-limit")
            return
        }

        fragments.append("\(error.domain)#\(error.code):\(error.localizedDescription)")

        if let detailedErrors = error.userInfo["NSDetailedErrors"] as? [NSError], !detailedErrors.isEmpty {
            for detailedError in detailedErrors {
                appendErrorDescription(detailedError, to: &fragments, depth: depth + 1)
            }
        }

        if let underlyingError = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            appendErrorDescription(underlyingError, to: &fragments, depth: depth + 1)
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

    private func resolveExportWaiters(completedAt completionDate: Date, result: ExportWaitResult) {
        let eligibleWaiterIDs = exportWaiters.compactMap { waiterID, waiter in
            waiter.registeredAt <= completionDate ? waiterID : nil
        }

        guard !eligibleWaiterIDs.isEmpty else { return }

        for waiterID in eligibleWaiterIDs {
            resolveExportWaiter(id: waiterID, result: result)
        }
    }

    private func resolveExportWaiter(id: UUID, result: ExportWaitResult) {
        guard let waiter = exportWaiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(returning: result)
    }
}
