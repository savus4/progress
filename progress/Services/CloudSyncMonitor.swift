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

    private var observer: NSObjectProtocol?

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
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var statusSymbolName: String {
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
        if case .failed = syncState {
            return true
        }
        return false
    }

    var statusTitle: String {
        if isRunningMigration {
            return "Preparing older photos for iCloud sync"
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
}
