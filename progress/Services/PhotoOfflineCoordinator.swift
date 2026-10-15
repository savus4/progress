@preconcurrency import BackgroundTasks
import CloudKit
@preconcurrency import CoreData
import Foundation
import Network
import Observation
import OSLog

/// The main actor owns UI state and lifecycle; the store actor and file workers
/// perform file work without blocking rendering or sharing managed objects.
@MainActor @Observable
final class PhotoOfflineCoordinator {
    static let shared = PhotoOfflineCoordinator()
    nonisolated static let backgroundTaskIdentifier = "me.riepl.progress.photo-offline"
    private static let storagePausedKey = "offlinePhotoDownloadsPausedForStorage"

    private(set) var selectedPhotoCount = 0
    private(set) var availablePhotoCount = 0
    private(set) var offlineBytes: Int64 = 0
    private(set) var recentPhotoBytes: Int64 = 0
    private(set) var heartedPhotoBytes: Int64 = 0
    private(set) var remainingDownloadBytes: Int64?
    private(set) var statusMessage = "Photos download when you open them."
    private(set) var isDownloading = false
    var hasMissingPhotos: Bool { availablePhotoCount < selectedPhotoCount || hasUnresolvedRecentPhotos }
    private var hasUnresolvedRecentPhotos = false

    @ObservationIgnored private let cloud: CloudKitService
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let injectedContext: NSManagedObjectContext?
    @ObservationIgnored private let capacityProvider: @Sendable () async -> Int64?
    @ObservationIgnored private let conditionsProvider: (@MainActor () -> String?)?
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var networkConnected = false
    @ObservationIgnored private var networkExpensive = false
    @ObservationIgnored private var networkConstrained = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var runID = UUID()
    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var preferenceValues: [Double] = []
    @ObservationIgnored private var budgetedPhotoIDs: Set<UUID> = []
    @ObservationIgnored private var budgetedRecentAssetNames: Set<String> = []
    @ObservationIgnored private var heartedAssetNames: Set<String> = []
    @ObservationIgnored private var retryDelay: Double = 30
    @ObservationIgnored private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "progress", category: "PhotoOffline")

    init(
        cloudKitService: CloudKitService = .shared,
        context: NSManagedObjectContext? = nil,
        capacityProvider: @escaping @Sendable () async -> Int64? = { await PhotoOfflineStorageCapacity.availableBytes() },
        conditionsProvider: (@MainActor () -> String?)? = nil
    ) {
        cloud = cloudKitService
        defaults = cloudKitService.offlineSettingsDefaults
        injectedContext = context
        self.capacityProvider = capacityProvider
        self.conditionsProvider = conditionsProvider
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        preferenceValues = readPreferenceValues()
        let names: [Notification.Name] = [
            .NSManagedObjectContextDidSave, .NSPersistentStoreRemoteChange,
            PhotoUploadService.didCompleteUploadNotification,
            CloudKitService.photoAccessDidChangeNotification,
            ICloudAvailabilityMonitor.availabilityDidChangeNotification,
            .NSProcessInfoPowerStateDidChange
        ]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.requestReconciliation() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, preferenceValues != readPreferenceValues() else { return }
                preferencesDidChange()
            }
        })
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            let expensive = path.isExpensive
            let constrained = path.isConstrained
            Task { @MainActor [weak self] in
                guard let self else { return }
                networkConnected = connected
                networkExpensive = expensive
                networkConstrained = constrained
                requestReconciliation()
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "progress.photo-offline.network"))
        requestReconciliation()
    }

    func preferencesDidChange() {
        preferenceValues = readPreferenceValues()
        retryDelay = 30
        requestReconciliation(delay: .zero)
        scheduleBackgroundProcessing()
    }

    func requestReconciliation(delay: Duration = .milliseconds(400)) {
        worker?.cancel()
        retryTask?.cancel()
        let id = UUID()
        runID = id
        worker = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            await reconcile(id: id)
        }
    }

    func reconcileNow() async {
        requestReconciliation(delay: .zero)
        // A save or the first network update may replace the worker while a
        // background task is waiting. Wait for the replacement too.
        while !Task.isCancelled {
            let id = runID
            await worker?.value
            if runID == id { break }
        }
    }

    func cancelPendingWork() {
        worker?.cancel()
        retryTask?.cancel()
    }

    private func reconcile(id: UUID) async {
        isDownloading = false
        defer { if runID == id { isDownloading = false } }
        do {
            let context = injectedContext ?? PersistenceController.shared.makeBackgroundContext()
            let photos = try await fetchPhotos(in: context)
            try Task.checkCancellation()
            heartedAssetNames = Set(photos.filter { $0.isHearted || $0.isFavoriteLivePhoto }.flatMap { $0.assetNames })
            let policy = PhotoOfflineSettings.policy(in: defaults)
            let pinned = photos.filter { $0.isSelected(by: policy) }
            let recentSelection = try await selectRecentPhotos(from: photos, protected: pinned, policy: policy)
            hasUnresolvedRecentPhotos = recentSelection.hasUnknownSizes
            let pinnedIDs = Set(pinned.map(\.id))
            let selected = (pinned + recentSelection.photos.filter { !pinnedIDs.contains($0.id) }).sorted {
                let lhsHearted = $0.isHearted || $0.isFavoriteLivePhoto
                let rhsHearted = $1.isHearted || $1.isFavoriteLivePhoto
                if lhsHearted != rhsHearted { return lhsHearted }
                return $0.createdAt > $1.createdAt
            }
            budgetedPhotoIDs = Set(selected.map(\.id))
            selectedPhotoCount = selected.count
            let desiredNames = Set(selected.flatMap { $0.assetNames })
            let liveIDs = Set(photos.map(\.id))
            let pendingNames = Set(cloud.uploadStateStore.allEntries().filter {
                $0.state != .uploaded && liveIDs.contains($0.photoID)
            }.flatMap(\.assetNames))
            try await cloud.releaseOfflineCopies(except: desiredNames.union(pendingNames))
            try Task.checkCancellation()

            // Recover the gap between recording upload success and moving/removing
            // staging files, including interrupted multi-resource Live handoffs.
            for entry in cloud.uploadStateStore.allEntries() where entry.state == .uploaded && liveIDs.contains(entry.photoID) {
                let keep = selected.contains { $0.id == entry.photoID }
                try await cloud.finishUploadedOriginals(assetNames: entry.assetNames, retaining: keep)
                try Task.checkCancellation()
            }
            var availableNames = try await cloud.offlineStore.assetNames().union(cloud.storedPersistentAssetNames())
            await updateProgress(selected, availableNames: availableNames)
            remainingDownloadBytes = nil
            if selected.isEmpty || !hasMissingPhotos {
                remainingDownloadBytes = 0
                statusMessage = recentSelection.hasUnknownSizes
                    ? (downloadPauseReason() ?? "Some photo sizes aren’t available yet.")
                    : selected.isEmpty ? "No photos kept offline." : "All selected photos are available offline."
                defaults.set(false, forKey: Self.storagePausedKey)
                if recentSelection.hasUnknownSizes { scheduleRetry() }
                return
            }
            if let reason = downloadPauseReason() { statusMessage = reason; return }

            let cellular = PhotoOfflineSettings.allowsCellular(in: defaults)
            var metadata: [String: PhotoAssetMetadata] = [:]
            var metadataErrors: [String: String] = [:]
            statusMessage = "Calculating download size…"
            let missingNames = desiredNames.subtracting(availableNames).sorted()
            for offset in stride(from: 0, to: missingNames.count, by: 100) {
                try Task.checkCancellation()
                if let reason = downloadPauseReason() { statusMessage = reason; return }
                let batch = Array(missingNames[offset..<min(offset + 100, missingNames.count)])
                let results = try await cloud.offlineAssetMetadata(named: batch, allowsCellularAccess: cellular)
                for name in batch {
                    switch results[name] {
                    case .success(let value): metadata[name] = value
                    case .failure(let error): metadataErrors[name] = error.localizedDescription
                    case nil: metadataErrors[name] = "Original metadata is not available yet."
                    }
                }
            }
            try Task.checkCancellation()
            if metadataErrors.isEmpty { remainingDownloadBytes = metadata.values.reduce(0) { $0 + $1.byteCount } }
            var failedCount = 0
            for photo in selected where !photo.isAvailable(in: availableNames) {
                try Task.checkCancellation()
                if let reason = downloadPauseReason() { statusMessage = reason; return }
                let missing = photo.assetNames.subtracting(availableNames)
                guard photo.fullImageAssetName != nil, missing.allSatisfy({ metadata[$0] != nil }) else {
                    failedCount += 1
                    continue
                }
                let requiredBytes = missing.reduce(Int64(0)) { $0 + (metadata[$1]?.byteCount ?? 0) }
                guard let capacity = await capacityProvider() else {
                    statusMessage = "Downloads paused because available device storage couldn’t be checked."
                    scheduleRetry()
                    return
                }
                try Task.checkCancellation()
                guard PhotoOfflineSettings.canDownload(
                    availableBytes: capacity, requiredBytes: requiredBytes,
                    wasPaused: defaults.bool(forKey: Self.storagePausedKey)
                ) else {
                    defaults.set(true, forKey: Self.storagePausedKey)
                    statusMessage = "Downloads paused: device storage is low."
                    scheduleRetry()
                    return
                }
                defaults.set(false, forKey: Self.storagePausedKey)
                isDownloading = true
                statusMessage = "Downloading photos for offline use…"
                do {
                    for name in missing.sorted() {
                        try Task.checkCancellation()
                        let source = try await cloud.loadAssetURL(named: name, allowsCellularAccess: cellular)
                        try Task.checkCancellation()
                        guard try await isStillSelected(photo.id, in: context) else { break }
                        try await cloud.offlineStore.retain(from: source, named: name, expected: metadata[name])
                        try Task.checkCancellation()
                        guard try await isStillSelected(photo.id, in: context) else {
                            try await cloud.offlineStore.remove(named: name)
                            break
                        }
                        availableNames.insert(name)
                        if let remainingDownloadBytes { self.remainingDownloadBytes = max(0, remainingDownloadBytes - (metadata[name]?.byteCount ?? 0)) }
                        await updateProgress(selected, availableNames: availableNames)
                    }
                } catch {
                    try Task.checkCancellation()
                    let nsError = error as NSError
                    if nsError.domain == NSCocoaErrorDomain && nsError.code == CocoaError.fileWriteOutOfSpace.rawValue {
                        defaults.set(true, forKey: Self.storagePausedKey)
                        statusMessage = "Downloads paused: device storage is full."
                        scheduleRetry()
                        return
                    }
                    failedCount += 1
                    logger.error("offline-photo-download: \(error.localizedDescription, privacy: .public)")
                }
            }
            await updateProgress(selected, availableNames: availableNames)
            if hasMissingPhotos || failedCount > 0 || recentSelection.hasUnknownSizes {
                statusMessage = "Some originals aren’t available yet."
                scheduleRetry()
            } else {
                remainingDownloadBytes = 0
                statusMessage = "All selected photos are available offline."
                retryDelay = 30
            }
        } catch is CancellationError {
            // Settings, saves, and background expiration restart from durable files.
        } catch {
            guard !Task.isCancelled else { return }
            statusMessage = "Offline storage needs attention: \(error.localizedDescription)"
            logger.error("offline-reconcile: \(error.localizedDescription, privacy: .public)")
            scheduleRetry()
        }
    }

    private func selectRecentPhotos(from photos: [PhotoOfflinePhoto], protected pinned: [PhotoOfflinePhoto], policy: PhotoOfflinePolicy) async throws -> PhotoRecentSelection {
        let empty = PhotoRecentSelection(photos: [], accessDates: [:], metadata: [:], limitBytes: 0, protectedNames: [])
        guard policy != .all, PhotoOfflineSettings.keepsRecentPhotos(in: defaults) else {
            recentPhotoBytes = 0
            budgetedRecentAssetNames = []
            return empty
        }
        let accesses = try await cloud.offlineStore.accessDates()
        let recent = photos.filter { accesses[$0.fullImageAssetName ?? ""] != nil }
        let names = Set(recent.flatMap { $0.assetNames })
        var metadata = try await cloud.localAssetMetadata(named: names)
        let unknownNames = names.subtracting(metadata.keys).sorted()
        if downloadPauseReason() == nil {
            let cellular = PhotoOfflineSettings.allowsCellular(in: defaults)
            for offset in stride(from: 0, to: unknownNames.count, by: 100) {
                try Task.checkCancellation()
                let batch = Array(unknownNames[offset..<min(offset + 100, unknownNames.count)])
                let values = try await cloud.offlineAssetMetadata(named: batch, allowsCellularAccess: cellular)
                for (name, result) in values {
                    if case .success(let value) = result { metadata[name] = value }
                }
            }
        }
        try Task.checkCancellation()
        let selection = PhotoRecentSelection(
            photos: recent, accessDates: accesses, metadata: metadata,
            limitBytes: PhotoOfflineSettings.recentLimitBytes(in: defaults),
            protectedNames: Set(pinned.flatMap { $0.assetNames })
        )
        try await cloud.offlineStore.removeAccessRecords(except: selection.retainedAccessNames)
        budgetedRecentAssetNames = Set(selection.photos.flatMap { $0.assetNames }).subtracting(pinned.flatMap { $0.assetNames })
        return selection
    }

    private func updateProgress(_ selected: [PhotoOfflinePhoto], availableNames: Set<String>) async {
        let metadata = (try? await cloud.offlineStore.assetMetadata()) ?? [:]
        guard !Task.isCancelled else { return }
        availablePhotoCount = selected.filter { $0.isAvailable(in: availableNames) }.count
        offlineBytes = metadata.values.reduce(0) { $0 + $1.byteCount }
        recentPhotoBytes = metadata.filter { budgetedRecentAssetNames.contains($0.key) }.values.reduce(0) { $0 + $1.byteCount }
        heartedPhotoBytes = metadata.filter { heartedAssetNames.contains($0.key) }.values.reduce(0) { $0 + $1.byteCount }
    }

    private func fetchPhotos(in context: NSManagedObjectContext) async throws -> [PhotoOfflinePhoto] {
        try await context.perform {
            let request = NSFetchRequest<NSDictionary>(entityName: "DailyPhoto")
            request.resultType = .dictionaryResultType
            request.propertiesToFetch = ["id", "createdAt", "isHearted", "isFavoriteLivePhoto", "fullImageAssetName", "livePhotoImageAssetName", "livePhotoVideoAssetName"]
            request.sortDescriptors = [NSSortDescriptor(key: "id", ascending: true)]
            request.fetchLimit = 200
            var photos: [PhotoOfflinePhoto] = []
            while true {
                let rows = try context.fetch(request)
                photos.append(contentsOf: rows.compactMap { row in
                    guard let id = row["id"] as? UUID else { return nil }
                    return PhotoOfflinePhoto(
                        id: id, createdAt: row["createdAt"] as? Date ?? .distantPast,
                        isHearted: (row["isHearted"] as? NSNumber)?.boolValue ?? false,
                        isFavoriteLivePhoto: (row["isFavoriteLivePhoto"] as? NSNumber)?.boolValue ?? false,
                        fullImageAssetName: row["fullImageAssetName"] as? String,
                        livePhotoImageAssetName: row["livePhotoImageAssetName"] as? String,
                        livePhotoVideoAssetName: row["livePhotoVideoAssetName"] as? String
                    )
                })
                if rows.count < request.fetchLimit { break }
                request.fetchOffset += rows.count
            }
            return photos
        }
    }

    private func isStillSelected(_ photoID: UUID, in context: NSManagedObjectContext) async throws -> Bool {
        let policy = PhotoOfflineSettings.policy(in: defaults)
        let isBudgeted = PhotoOfflineSettings.keepsRecentPhotos(in: defaults) && budgetedPhotoIDs.contains(photoID)
        return try await context.perform {
            let request = DailyPhoto.fetchRequest()
            request.fetchLimit = 1
            request.predicate = NSPredicate(format: "id == %@", photoID as NSUUID)
            guard let photo = try context.fetch(request).first, !photo.isDeleted else { return false }
            return policy.selects(isHearted: photo.isHearted, isFavoriteLivePhoto: photo.isFavoriteLivePhoto) || isBudgeted
        }
    }

    private func downloadPauseReason() -> String? {
        if let conditionsProvider { return conditionsProvider() }
        if ICloudAvailabilityMonitor.shared.state != .available { return "Waiting for iCloud to become available." }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return "Downloads paused by Low Power Mode." }
        return PhotoOfflineSettings.networkPauseReason(
            isConnected: networkConnected, isExpensive: networkExpensive,
            isConstrained: networkConstrained, allowsCellular: PhotoOfflineSettings.allowsCellular(in: defaults)
        )
    }

    private func readPreferenceValues() -> [Double] {
        [PhotoOfflineSettings.keepAllKey, PhotoOfflineSettings.keepHeartedKey, PhotoOfflineSettings.cellularKey, PhotoOfflineSettings.recentPhotosKey].map { defaults.bool(forKey: $0) ? 1 : 0 }
            + [Double(PhotoOfflineSettings.recentLimitBytes(in: defaults))]
    }

    private func scheduleRetry() {
        guard didStart else { return }
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 900)
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.requestReconciliation(delay: .zero)
        }
        scheduleBackgroundProcessing(earliestBeginDate: Date().addingTimeInterval(delay))
    }

    nonisolated static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundTaskIdentifier, using: nil) { task in
            guard let task = task as? BGProcessingTask else { task.setTaskCompleted(success: false); return }
            let work = Task { @MainActor in
                defer { task.expirationHandler = nil }
                // A background launch can deliver this handler before the
                // persistent store has finished opening.
                for _ in 0..<300 {
                    if PersistenceController.shared.isLoaded { break }
                    if case .failed = PersistenceController.shared.loadState { break }
                    if Task.isCancelled { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                guard !Task.isCancelled, PersistenceController.shared.isLoaded else {
                    task.setTaskCompleted(success: false)
                    shared.scheduleBackgroundProcessing(earliestBeginDate: Date().addingTimeInterval(900))
                    return
                }
                shared.start()
                await shared.reconcileNow()
                task.setTaskCompleted(success: !Task.isCancelled && !shared.hasMissingPhotos)
                if shared.hasMissingPhotos { shared.scheduleBackgroundProcessing(earliestBeginDate: Date().addingTimeInterval(900)) }
            }
            task.expirationHandler = {
                work.cancel()
                Task { @MainActor in shared.cancelPendingWork() }
            }
        }
    }

    func scheduleBackgroundProcessing(earliestBeginDate: Date? = nil) {
        guard PhotoOfflineSettings.policy(in: defaults) != .onDemand || PhotoOfflineSettings.keepsRecentPhotos(in: defaults) else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundTaskIdentifier)
            return
        }
        let request = BGProcessingTaskRequest(identifier: Self.backgroundTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = earliestBeginDate
        do { try BGTaskScheduler.shared.submit(request) }
        catch { logger.debug("offline-bg-schedule: \(error.localizedDescription, privacy: .public)") }
    }

    isolated deinit {
        worker?.cancel()
        retryTask?.cancel()
        pathMonitor.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}
