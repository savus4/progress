import CoreData
import Foundation

/// Import server identities before adding local rows. Copying a previously
/// mirrored store would also copy local-only deletions back into iCloud.
@MainActor
enum PhotoCloudLibraryPreparation {
    static func prepare(from source: NSPersistentContainer, at url: URL, mirrorsCloud: Bool,
                        loader: (@MainActor (NSPersistentContainer) async throws -> Void)? = nil,
                        validateAccount: @MainActor () async throws -> Void) async throws {
        let target: NSPersistentContainer = mirrorsCloud
            ? NSPersistentCloudKitContainer(name: "progress", managedObjectModel: source.managedObjectModel)
            : NSPersistentContainer(name: "progress", managedObjectModel: source.managedObjectModel)
        let description = NSPersistentStoreDescription(url: url)
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        if mirrorsCloud {
            description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
                containerIdentifier: CloudKitConfiguration.containerIdentifier
            )
        }
        target.persistentStoreDescriptions = [description]
        var prepared = false
        defer {
            target.viewContext.reset()
            for store in target.persistentStoreCoordinator.persistentStores {
                try? target.persistentStoreCoordinator.remove(store)
            }
            if !prepared {
                try? target.persistentStoreCoordinator.destroyPersistentStore(at: url, type: .sqlite)
            }
        }
        if let loader { try await loader(target) }
        else { try await load(target) }
        try Task.checkCancellation()
        try await validateAccount()

        let sourceContext = source.newBackgroundContext()
        let targetContext = target.newBackgroundContext()
        let ids = try await sourceContext.perform {
            let request = NSFetchRequest<NSManagedObjectID>(entityName: "DailyPhoto")
            request.resultType = .managedObjectIDResultType
            return try sourceContext.fetch(request)
        }
        for objectID in ids {
            try Task.checkCancellation()
            let (id, attributes) = try await sourceContext.perform {
                let photo = try sourceContext.existingObject(with: objectID)
                defer { sourceContext.refresh(photo, mergeChanges: false) }
                guard let id = photo.value(forKey: "id") as? UUID else {
                    throw CocoaError(.validationMissingMandatoryProperty)
                }
                let attributes = try photo.entity.attributesByName.reduce(into: [String: PhotoLibraryAttribute]()) { result, entry in
                    if let value = photo.value(forKey: entry.key) {
                        result[entry.key] = try PhotoLibraryAttribute(value: value, type: entry.value.attributeType)
                    }
                }
                return (id, attributes)
            }
            try await targetContext.perform {
                let request = DailyPhoto.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", id as NSUUID)
                request.fetchLimit = 1
                let photo = try targetContext.fetch(request).first ?? DailyPhoto(context: targetContext)
                // Apply nils too, so clearing a local field survives the merge.
                for key in photo.entity.attributesByName.keys {
                    photo.setValue(attributes[key]?.value, forKey: key)
                }
                try targetContext.save()
                targetContext.reset()
            }
        }
        try Task.checkCancellation()
        try await validateAccount()
        prepared = true
    }

    static func load(_ container: NSPersistentContainer, timeout: Duration = .seconds(120)) async throws {
        guard container.persistentStoreDescriptions.contains(where: { $0.cloudKitContainerOptions != nil }) else {
            try await loadStores(container)
            return
        }
        let (events, continuation) = AsyncThrowingStream<Void, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification, object: container, queue: nil
        ) { notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event,
                  event.endDate != nil, event.type == .setup || event.type == .import else { return }
            if let error = event.error { continuation.finish(throwing: error) }
            else if event.type == .import, event.succeeded {
                continuation.yield(())
                continuation.finish()
            }
        }
        let timeoutTask = Task {
            do { try await Task.sleep(for: timeout) }
            catch { return }
            guard !Task.isCancelled else { return }
            continuation.finish(throwing: PhotoStorageMigrationError.attention(
                "The iCloud library couldn’t finish downloading. Your local photos are safe. Check your connection and retry the storage switch."
            ))
        }
        defer {
            timeoutTask.cancel()
            NotificationCenter.default.removeObserver(observer)
            continuation.finish()
        }
        try await loadStores(container)
        for try await _ in events {
            try Task.checkCancellation()
            return
        }
        try Task.checkCancellation()
        throw CocoaError(.persistentStoreOperation)
    }

    private static func loadStores(_ container: NSPersistentContainer) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            container.loadPersistentStores { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
}
