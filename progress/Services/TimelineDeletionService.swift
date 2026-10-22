import CoreData
import Foundation
import OSLog

/// A synced tombstone is the durable deletion intent. Cleanup can resume after
/// termination and also removes photos arriving later from an offline device.
@MainActor
final class TimelineDeletionService {
    static let shared = TimelineDeletionService(
        guideCloudStore: StorageTestConfiguration.usesEphemeralLibrary ? nil : .default
    )

    private let photos: PhotoStorageService
    private let reminders: DailyReminderNotificationService
    private let guideDefaults: UserDefaults
    private let guideCloudStore: NSUbiquitousKeyValueStore?
    private let automaticallyReconciles: Bool
    private let storageModeStore: PhotoStorageModeStore
    private var context: NSManagedObjectContext?
    private var observers: [NSObjectProtocol] = []
    private var reconciliationTask: Task<Void, Never>?
    private var isReconciling = false
    private var needsReconciliation = false
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "progress", category: "TimelineDeletion")

    init(photos: PhotoStorageService = .shared, reminders: DailyReminderNotificationService = .shared,
         guideDefaults: UserDefaults = .standard, guideCloudStore: NSUbiquitousKeyValueStore? = .default,
         automaticallyReconciles: Bool = true, storageModeStore: PhotoStorageModeStore = .shared) {
        self.photos = photos
        self.reminders = reminders
        self.guideDefaults = guideDefaults
        self.guideCloudStore = guideCloudStore
        self.automaticallyReconciles = automaticallyReconciles
        self.storageModeStore = storageModeStore
    }

    isolated deinit {
        reconciliationTask?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func start(in context: NSManagedObjectContext) {
        if self.context !== context {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
        }
        self.context = context
        if observers.isEmpty {
            for name in [Notification.Name.NSManagedObjectContextDidSave, .NSPersistentStoreRemoteChange] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.requestReconciliation() }
                })
            }
            observers.append(NotificationCenter.default.addObserver(
                forName: .NSManagedObjectContextObjectsDidChange, object: context, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.requestReconciliation() }
            })
        }
        requestReconciliation()
    }

    func delete(id: UUID, in context: NSManagedObjectContext) async throws {
        guard !PhotoImportCoordinator.shared.isImporting else { throw TimelineOperationError.importInProgress }
        try await TimelineStore.markDeleted(id: id, in: context, storageMode: storageModeStore.mode)
        let reminderRemoval = forgetLocalSettings(for: [id], localOnlyIDs: storageModeStore.mode.allowsCloudWrites ? [] : [id])
        self.context = context
        requestReconciliation()
        _ = await reminderRemoval.value
    }

    /// Public for deterministic recovery tests as well as the startup worker.
    func reconcile(in context: NSManagedObjectContext) async throws {
        guard !isReconciling else { needsReconciliation = true; return }
        guard !storageModeStore.mode.isMigrating else { return }
        isReconciling = true
        defer { isReconciling = false }
        repeat {
            needsReconciliation = false
            try Task.checkCancellation()
            let state = try await TimelineStore.state(in: context)
            guard !state.deletedIDs.isEmpty else { return }
            try await TimelineStore.normalizeTombstones(in: context)
            let localOnlyIDs = try await context.perform {
                Set(try context.fetch(Timeline.fetchRequest()).filter { $0.localDeletedAt != nil && $0.deletedAt == nil }.compactMap(\.id))
            }
            _ = await forgetLocalSettings(for: state.deletedIDs, localOnlyIDs: localOnlyIDs).value
            for id in state.deletedIDs {
                while true {
                    try Task.checkCancellation()
                    guard !storageModeStore.mode.isMigrating else { return }
                    let objectIDs = try await context.perform {
                        let request = NSFetchRequest<NSManagedObjectID>(entityName: "DailyPhoto")
                        request.resultType = .managedObjectIDResultType
                        request.predicate = TimelineIdentity.photoPredicate(for: id)
                        request.fetchLimit = 200
                        return try context.fetch(request)
                    }
                    guard !objectIDs.isEmpty else { break }
                    _ = try await photos.deletePhotos(objectIDs, context: context, deletesAssetsInBackground: false)
                }
            }
        } while needsReconciliation
    }

    func waitForPendingCleanup() async {
        await reconciliationTask?.value
    }

    private func requestReconciliation() {
        needsReconciliation = true
        guard automaticallyReconciles else { return }
        guard reconciliationTask == nil, let context else { return }
        reconciliationTask = Task { [weak self] in
            guard let self else { return }
            defer { reconciliationTask = nil }
            do {
                try await Task.sleep(for: .milliseconds(250))
                try await reconcile(in: context)
            } catch is CancellationError {
            } catch {
                // The tombstone remains durable; the next save/import/start retries.
                logger.error("timeline-cleanup-pending error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func forgetLocalSettings(for ids: Set<UUID>, localOnlyIDs: Set<UUID> = []) -> Task<Bool, Never> {
        let removal = reminders.removeTimelines(ids)
        for id in ids {
            AlignmentGuideStore.removeSettings(for: id, localDefaults: guideDefaults, ubiquitousStore: guideCloudStore, storageModeStore: storageModeStore, syncsDeletion: !localOnlyIDs.contains(id))
        }
        return removal
    }
}
