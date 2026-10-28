import CoreData
import Foundation
import Observation

/// Names live in the mirrored library; the current selection belongs to this device.
@MainActor
@Observable
final class TimelineSelectionStore: NSObject {
    static let shared = TimelineSelectionStore()
    static let selectedTimelineKey = "selectedTimelineID"

    private(set) var selectedID: UUID
    private(set) var timelines: [TimelineSnapshot] = [TimelineSnapshot(
        id: TimelineIdentity.defaultID, name: TimelineIdentity.defaultName, createdAt: nil, modifiedAt: nil
    )]
    private(set) var isLoaded = false
    private(set) var errorMessage: String?
    private(set) var deletedIDs: Set<UUID> = []
    private(set) var isDeleting = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var observedContext: NSManagedObjectContext?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshContext: NSManagedObjectContext?
    @ObservationIgnored private var needsRefresh = false

    var selectedName: String {
        timelines.first { $0.id == selectedID }?.name
            ?? (selectedID == TimelineIdentity.defaultID ? TimelineIdentity.defaultName : "Timeline")
    }

    var canRenameTimelines: Bool { isLoaded && !timelines.isEmpty }

    func canDeleteTimeline(_ id: UUID) -> Bool {
        isLoaded && timelines.count > 1 && timelines.contains(where: { $0.id == id }) && !deletedIDs.contains(id)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedID = defaults.string(forKey: Self.selectedTimelineKey).flatMap(UUID.init(uuidString:))
            ?? TimelineIdentity.defaultID
        super.init()
    }

    isolated deinit {
        refreshTask?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func start(in context: NSManagedObjectContext) async {
        observeChanges(in: context)
        await refresh(in: context)
    }

    private func observeChanges(in context: NSManagedObjectContext) {
        guard observedContext !== context else { return }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observedContext = context
        // Only value snapshots survive a store switch. An FRC can retain results
        // from the removed store and throw inside the next save's change processing.
        observers = [NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextObjectsDidChange, object: context, queue: nil
        ) { [weak self, weak context] notification in
            guard Self.affectsTimelines(notification) else { return }
            Task { @MainActor [weak self, weak context] in
                guard let self, let context, self.observedContext === context else { return }
                await self.refresh(in: context)
            }
        }]
        if let coordinator = context.persistentStoreCoordinator {
            observers.append(NotificationCenter.default.addObserver(
                forName: .NSManagedObjectContextDidSaveObjectIDs, object: nil, queue: nil
            ) { [weak self, weak context] notification in
                // The view context may hold no registered Timeline objects, so
                // its objects-did-change notification can omit background edits.
                guard let savedContext = notification.object as? NSManagedObjectContext,
                      savedContext.persistentStoreCoordinator === coordinator,
                      Self.affectsTimelineIDs(notification) else { return }
                Task { @MainActor [weak self, weak context] in
                    guard let self, let context, self.observedContext === context else { return }
                    await self.refresh(in: context)
                }
            })
            for name in [Notification.Name.NSPersistentStoreCoordinatorStoresDidChange, .NSPersistentStoreRemoteChange] {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: coordinator, queue: nil
                ) { [weak self, weak context] _ in
                    // Store notifications may arrive on Core Data's internal thread.
                    Task { @MainActor [weak self, weak context] in
                        guard let self, let context, self.observedContext === context else { return }
                        await self.refresh(in: context)
                    }
                })
            }
        }
    }

    nonisolated private static func affectsTimelineIDs(_ notification: Notification) -> Bool {
        [NSInsertedObjectIDsKey, NSUpdatedObjectIDsKey, NSDeletedObjectIDsKey].contains { key in
            let ids = notification.userInfo?[key] as? Set<NSManagedObjectID> ?? []
            return ids.contains { $0.entity.name == "Timeline" }
        }
    }

    nonisolated private static func affectsTimelines(_ notification: Notification) -> Bool {
        if notification.userInfo?[NSInvalidatedAllObjectsKey] != nil { return true }
        return [NSInsertedObjectsKey, NSUpdatedObjectsKey, NSDeletedObjectsKey,
                NSRefreshedObjectsKey, NSInvalidatedObjectsKey].contains { key in
            let objects = notification.userInfo?[key] as? Set<NSManagedObject> ?? []
            return objects.contains { $0.entity.name == "Timeline" }
        }
    }

    func refresh(in context: NSManagedObjectContext) async {
        refreshContext = context
        needsRefresh = true
        if let refreshTask {
            await refreshTask.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            defer { refreshTask = nil }
            repeat {
                needsRefresh = false
                guard let currentContext = refreshContext else { return }
                let stores = Set((currentContext.persistentStoreCoordinator?.persistentStores ?? []).map(ObjectIdentifier.init))
                guard !stores.isEmpty else {
                    isLoaded = false
                    continue
                }
                do {
                    try await TimelineStore.ensureAvailableTimeline(in: currentContext)
                    try await TimelineStore.resolveNameConflicts(in: currentContext)
                    let state = try await TimelineStore.state(in: currentContext)
                    guard refreshContext === currentContext else { continue }
                    guard stores == Set((currentContext.persistentStoreCoordinator?.persistentStores ?? []).map(ObjectIdentifier.init)) else {
                        needsRefresh = true
                        continue
                    }
                    apply(state)
                } catch {
                    guard refreshContext === currentContext else { continue }
                    errorMessage = error.localizedDescription
                }
            } while needsRefresh
        }
        refreshTask = task
        await task.value
    }

    private func apply(_ state: TimelineLibraryState) {
        deletedIDs = state.deletedIDs
        var snapshots = state.timelines
        if deletedIDs.contains(selectedID), let survivor = snapshots.first {
            selectedID = survivor.id
            defaults.set(survivor.id.uuidString, forKey: Self.selectedTimelineKey)
        }
        // Unknown owners can still be awaiting metadata, but tombstoned owners
        // must never become placeholder timelines or destinations for new captures.
        if !snapshots.contains(where: { $0.id == selectedID }) {
            snapshots.append(TimelineSnapshot(id: selectedID, name: selectedName, createdAt: nil, modifiedAt: nil))
        }
        timelines = snapshots
        isLoaded = true
        errorMessage = nil
    }

    @discardableResult
    func select(_ id: UUID) -> Bool {
        guard !deletedIDs.contains(id) else { return false }
        if !timelines.contains(where: { $0.id == id }) {
            timelines.append(TimelineSnapshot(id: id, name: "Timeline", createdAt: nil, modifiedAt: nil))
        }
        selectedID = id
        defaults.set(id.uuidString, forKey: Self.selectedTimelineKey)
        return true
    }

    @discardableResult
    func create(name: String, in context: NSManagedObjectContext) async throws -> UUID {
        let id = try await TimelineStore.create(name: name, in: context)
        select(id)
        await refresh(in: context)
        return id
    }

    func rename(id: UUID, to name: String, in context: NSManagedObjectContext) async throws {
        try await TimelineStore.rename(id: id, to: name, in: context)
        await refresh(in: context)
    }

    func setLivePhotoCaptureEnabled(_ enabled: Bool, for id: UUID, in context: NSManagedObjectContext) async throws {
        try await TimelineStore.setLivePhotoCaptureEnabled(enabled, for: id, in: context)
        await refresh(in: context)
    }

    func setCameraPosition(_ position: CameraPosition, for id: UUID, in context: NSManagedObjectContext) async throws {
        try await TimelineStore.setCameraPosition(position, for: id, in: context)
        await refresh(in: context)
    }

    func delete(id: UUID, in context: NSManagedObjectContext, using service: TimelineDeletionService = .shared) async throws {
        guard !isDeleting else { return }
        isDeleting = true
        defer { isDeleting = false }
        try await service.delete(id: id, in: context)
        await refresh(in: context)
    }
}
