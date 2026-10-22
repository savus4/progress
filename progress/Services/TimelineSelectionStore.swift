import CoreData
import Foundation
import Observation

/// Names live in the mirrored library; the current selection belongs to this device.
@MainActor
@Observable
final class TimelineSelectionStore: NSObject, NSFetchedResultsControllerDelegate {
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
    @ObservationIgnored private var resultsController: NSFetchedResultsController<Timeline>?
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

    func start(in context: NSManagedObjectContext) async {
        // Re-fetch even for the same context: a storage-mode switch reopens its store.
        if resultsController?.managedObjectContext !== context {
            resultsController?.delegate = nil
            let request = Timeline.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
            let controller = NSFetchedResultsController(
                fetchRequest: request, managedObjectContext: context,
                sectionNameKeyPath: nil, cacheName: nil
            )
            controller.delegate = self
            resultsController = controller
        }
        do {
            try resultsController?.performFetch()
            await refresh(in: context)
        } catch {
            errorMessage = error.localizedDescription
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
                do {
                    try await TimelineStore.ensureAvailableTimeline(in: currentContext)
                    try await TimelineStore.resolveNameConflicts(in: currentContext)
                    let state = try await TimelineStore.state(in: currentContext)
                    guard refreshContext === currentContext else { continue }
                    apply(state)
                } catch {
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

    func delete(id: UUID, in context: NSManagedObjectContext, using service: TimelineDeletionService = .shared) async throws {
        guard !isDeleting else { return }
        isDeleting = true
        defer { isDeleting = false }
        try await service.delete(id: id, in: context)
        await refresh(in: context)
    }

    func controllerDidChangeContent(_ controller: NSFetchedResultsController<any NSFetchRequestResult>) {
        guard controller === resultsController, let context = resultsController?.managedObjectContext else { return }
        Task { [weak self] in await self?.refresh(in: context) }
    }
}
