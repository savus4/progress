import CoreData
import Foundation

/// Reads only the existing thumbnail blobs, never the full-size photo assets.
@MainActor
final class PhotoThumbnailDataProvider: NSObject {
    private let context: NSManagedObjectContext
    private let cache = NSCache<NSManagedObjectID, NSData>()
    private var inFlight: [NSManagedObjectID: Task<[NSManagedObjectID: Data], Never>] = [:]
    private var generation = UUID()
    static let batchSize = 24

    init(context: NSManagedObjectContext = PersistenceController.shared.makeBackgroundContext()) {
        self.context = context
        super.init()
        cache.countLimit = 768
        cache.totalCostLimit = 16 * 1_024 * 1_024
        NotificationCenter.default.addObserver(
            self, selector: #selector(storeDidChange),
            name: .NSManagedObjectContextDidSaveObjectIDs, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(storeDidChange),
            name: .NSPersistentStoreRemoteChange, object: context.persistentStoreCoordinator
        )
    }

    isolated deinit {
        for task in inFlight.values { task.cancel() }
        NotificationCenter.default.removeObserver(self)
    }

    func thumbnailData(
        for objectID: NSManagedObjectID,
        nearbyObjectIDs: [NSManagedObjectID] = []
    ) async -> Data? {
        guard !objectID.isTemporaryID else { return nil }
        while !Task.isCancelled {
            if let data = cache.object(forKey: objectID) { return data as Data }
            let generation = generation
            let task = inFlight[objectID] ?? startBatch(for: objectID, nearbyObjectIDs: nearbyObjectIDs)
            let result = await task.value
            // A save or purge may race the fetch. Retry instead of leaving an idle cell blank.
            guard self.generation == generation else { continue }
            return Task.isCancelled ? nil : result[objectID]
        }
        return nil
    }

    private func startBatch(
        for objectID: NSManagedObjectID,
        nearbyObjectIDs: [NSManagedObjectID]
    ) -> Task<[NSManagedObjectID: Data], Never> {
        var seen: Set<NSManagedObjectID> = []
        let ids = ([objectID] + nearbyObjectIDs).filter {
            !$0.isTemporaryID && seen.insert($0).inserted
                && cache.object(forKey: $0) == nil && inFlight[$0] == nil
        }.prefix(Self.batchSize)
        let batchIDs = Array(ids)
        let generation = generation
        let context = context
        let task = Task { [weak self] in
            guard !Task.isCancelled else { return [NSManagedObjectID: Data]() }
            let result = await context.perform {
                autoreleasepool {
                    let identity = NSExpressionDescription()
                    identity.name = "objectID"
                    identity.expression = NSExpression.expressionForEvaluatedObject()
                    identity.expressionResultType = .objectIDAttributeType
                    let request = NSFetchRequest<NSDictionary>(entityName: "DailyPhoto")
                    request.resultType = .dictionaryResultType
                    request.includesPendingChanges = false
                    request.predicate = NSPredicate(format: "SELF IN %@", batchIDs)
                    request.propertiesToFetch = [identity, "thumbnailData"]
                    request.fetchLimit = batchIDs.count
                    let rows = (try? context.fetch(request)) ?? []
                    var result: [NSManagedObjectID: Data] = [:]
                    for row in rows {
                        if let id = row["objectID"] as? NSManagedObjectID,
                           let data = row["thumbnailData"] as? Data {
                            result[id] = data
                        }
                    }
                    return result
                }
            }
            guard let self, self.generation == generation, !Task.isCancelled else { return [:] }
            for id in batchIDs { self.inFlight[id] = nil }
            for (id, data) in result {
                self.cache.setObject(data as NSData, forKey: id, cost: data.count)
            }
            return result
        }
        for id in batchIDs { inFlight[id] = task }
        return task
    }

    func purge() {
        generation = UUID()
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        cache.removeAllObjects()
    }

    @objc nonisolated private func storeDidChange(_ notification: Notification) {
        Task { @MainActor [weak self] in self?.purge() }
    }
}
