//
//  Persistence.swift
//  progress
//
//  Created by Simon Riepl on 19.02.26.
//

import CoreData
import UIKit
import Combine
import OSLog

@MainActor
final class PersistenceController: ObservableObject {
    enum LoadState: Hashable {
        case loading
        case loaded
        case failed(String)
    }

    static let shared = PersistenceController()

    // Reuse entity descriptions across live, preview, and test containers so
    // DailyPhoto(context:) cannot resolve an entity from another model instance.
    private static let managedObjectModel: NSManagedObjectModel = {
        guard let url = Bundle(for: PersistenceController.self).url(forResource: "progress", withExtension: "momd"),
              let model = NSManagedObjectModel(contentsOf: url) else {
            preconditionFailure("Unable to load the progress Core Data model")
        }
        return model
    }()

    @MainActor
    static let preview: PersistenceController = {
        let result = PersistenceController(inMemory: true)
        let viewContext = result.container.viewContext
        
        // Create sample photos for preview
        for i in 0..<15 {
            let photo = DailyPhoto(context: viewContext)
            photo.id = UUID()
            photo.captureDate = Calendar.current.date(byAdding: .day, value: -i, to: Date())
            photo.createdAt = Date()
            photo.modifiedAt = Date()
            photo.latitude = 37.7749 + Double(i) * 0.01
            photo.longitude = -122.4194 + Double(i) * 0.01
            
            // Create a simple thumbnail placeholder
            if let placeholderImage = createPlaceholderImage() {
                photo.thumbnailData = placeholderImage.jpegData(compressionQuality: 0.7)
            }
        }
        
        do {
            try viewContext.save()
        } catch {
            assertionFailure("Preview store save failed: \(error.localizedDescription)")
        }
        return result
    }()
    
    private static func createPlaceholderImage() -> UIImage? {
        let size = CGSize(width: 300, height: 300)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor.systemGray5.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .center
            
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 40),
                .foregroundColor: UIColor.systemGray,
                .paragraphStyle: paragraphStyle
            ]
            
            let text = "📸"
            let textSize = text.size(withAttributes: attributes)
            let textRect = CGRect(
                x: (size.width - textSize.width) / 2,
                y: (size.height - textSize.height) / 2,
                width: textSize.width,
                height: textSize.height
            )
            
            text.draw(in: textRect, withAttributes: attributes)
        }
    }

    let container: NSPersistentContainer
    @Published private(set) var loadState: LoadState = .loading

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "progress",
        category: "Persistence"
    )
    private var pendingStoreLoads = 0
    private var firstStoreLoadError: Error?
    private var isLoadingStore = false
    private let storageModeStore: PhotoStorageModeStore
    private let cloudLibraryLoader: (@MainActor (NSPersistentContainer) async throws -> Void)?
    private let baseStoreURL: URL?

    init(inMemory: Bool = false, storageModeStore: PhotoStorageModeStore = .shared, storeURL: URL? = nil, cloudEnabled: Bool = true,
         cloudLibraryLoader: (@MainActor (NSPersistentContainer) async throws -> Void)? = nil) {
        self.storageModeStore = storageModeStore
        self.cloudLibraryLoader = cloudLibraryLoader
        let processInfo = ProcessInfo.processInfo
        let shouldUseInMemory = inMemory
            || (storeURL == nil && (processInfo.arguments.contains("UI_TEST_IN_MEMORY_STORE")
                || processInfo.environment["UI_TEST_IN_MEMORY_STORE"] == "1" || StorageTestConfiguration.isIsolatedHost))
        let usesExampleLibrary: Bool
        #if DEBUG && targetEnvironment(simulator)
        usesExampleLibrary = !shouldUseInMemory && SimulatorExampleLibrary.isEnabled
        #else
        usesExampleLibrary = false
        #endif
        container = if shouldUseInMemory || usesExampleLibrary || !cloudEnabled {
            NSPersistentContainer(name: "progress", managedObjectModel: Self.managedObjectModel)
        } else {
            NSPersistentCloudKitContainer(name: "progress", managedObjectModel: Self.managedObjectModel)
        }
        baseStoreURL = storeURL ?? container.persistentStoreDescriptions.first?.url
        for description in container.persistentStoreDescriptions {
            if let storeURL { description.url = storeURL }
            if !shouldUseInMemory, !usesExampleLibrary, let filename = storageModeStore.storeFilename {
                description.url = description.url?.deletingLastPathComponent().appendingPathComponent(filename)
            }
            if !storageModeStore.mode.allowsCloudWrites {
                description.cloudKitContainerOptions = nil
            }
            description.shouldMigrateStoreAutomatically = true
            description.shouldInferMappingModelAutomatically = true
            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        }
        if shouldUseInMemory {
            container.persistentStoreDescriptions.first!.type = NSInMemoryStoreType
        }
        #if DEBUG && targetEnvironment(simulator)
        if usesExampleLibrary {
            container.persistentStoreDescriptions.first!.url = NSPersistentContainer.defaultDirectoryURL()
                .appendingPathComponent("SimulatorExamples.sqlite")
        }
        #endif
        container.viewContext.name = "ViewContext"
        container.viewContext.mergePolicy = NSMergePolicy(
            merge: .mergeByPropertyObjectTrumpMergePolicyType
        )
        container.viewContext.automaticallyMergesChangesFromParent = true
        loadPersistentStores()
    }

    var isLoaded: Bool {
        loadState == .loaded
    }

    func retryLoading() {
        guard !isLoadingStore else { return }
        if container.persistentStoreCoordinator.persistentStores.isEmpty {
            loadPersistentStores()
        } else {
            prepareLoadedStore()
        }
    }

    private func loadPersistentStores() {
        isLoadingStore = true
        loadState = .loading
        firstStoreLoadError = nil
        pendingStoreLoads = max(container.persistentStoreDescriptions.count, 1)

        container.loadPersistentStores { [weak self] _, error in
            Task { @MainActor in
                self?.handlePersistentStoreLoad(error: error)
            }
        }
    }

    private func handlePersistentStoreLoad(error: Error?) {
        if let error, firstStoreLoadError == nil {
            firstStoreLoadError = error
        }

        pendingStoreLoads -= 1
        guard pendingStoreLoads <= 0 else { return }
        isLoadingStore = false

        if let firstStoreLoadError {
            logger.error("persistent-store-load-failed error=\(firstStoreLoadError.localizedDescription, privacy: .public)")
            loadState = .failed(firstStoreLoadError.localizedDescription)
        } else {
            prepareLoadedStore()
        }
    }

    private func prepareLoadedStore() {
        #if DEBUG && targetEnvironment(simulator)
        if container.persistentStoreDescriptions.first?.url?.lastPathComponent == "SimulatorExamples.sqlite",
           let resourceURL = SimulatorExampleLibrary.resourceURL {
            isLoadingStore = true
            loadState = .loading
            let context = makeBackgroundContext()
            Task {
                defer { isLoadingStore = false }
                do {
                    try await SimulatorExampleLibrary.seed(in: context, from: resourceURL)
                    loadState = .loaded
                    logger.log("simulator-examples-loaded")
                } catch {
                    logger.error("simulator-examples-failed error=\(error.localizedDescription, privacy: .public)")
                    loadState = .failed(error.localizedDescription)
                }
            }
            return
        }
        #endif
        logger.log("persistent-store-load-succeeded")
        loadState = .loaded
    }

    func makeBackgroundContext() -> NSManagedObjectContext {
        let context = container.newBackgroundContext()
        context.name = "BackgroundContext"
        context.mergePolicy = NSMergePolicy(
            merge: .mergeByPropertyObjectTrumpMergePolicyType
        )
        context.automaticallyMergesChangesFromParent = true
        return context
    }

    /// Reopens the selected SQLite store. Removing the store tears down mirroring;
    /// changing its description alone would leave the old mirroring delegate live.
    func reloadCloudConfiguration(cloudEnabled: Bool? = nil, storeFilename: String? = nil) async throws {
        guard !isLoadingStore else { throw CocoaError(.persistentStoreOperation) }
        loadState = .loading
        isLoadingStore = true
        do {
            if container.viewContext.hasChanges { try container.viewContext.save() }
            container.viewContext.reset()
            let coordinator = container.persistentStoreCoordinator
            for store in coordinator.persistentStores { try coordinator.remove(store) }
            for description in container.persistentStoreDescriptions {
                if let baseStoreURL {
                    description.url = (storeFilename ?? storageModeStore.storeFilename).map {
                        baseStoreURL.deletingLastPathComponent().appendingPathComponent($0)
                    } ?? baseStoreURL
                }
                description.cloudKitContainerOptions = (cloudEnabled ?? storageModeStore.mode.allowsCloudWrites)
                    && container is NSPersistentCloudKitContainer
                    ? NSPersistentCloudKitContainerOptions(containerIdentifier: CloudKitConfiguration.containerIdentifier) : nil
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                container.loadPersistentStores { _, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
            isLoadingStore = false
            loadState = .loaded
        } catch {
            isLoadingStore = false
            loadState = .failed(error.localizedDescription)
            throw error
        }
    }

    /// The active local store remains intact until the imported, merged store
    /// has opened successfully and its filename is committed to the checkpoint.
    func prepareLibraryForICloudStorage(validateAccount: @MainActor () async throws -> Void) async throws -> String {
        guard isLoaded, let directory = baseStoreURL?.deletingLastPathComponent() else {
            throw CocoaError(.persistentStoreOperation)
        }
        if container.viewContext.hasChanges { try container.viewContext.save() }
        let filename = "ICloudLibrary-\(UUID().uuidString).sqlite"
        try await PhotoCloudLibraryPreparation.prepare(
            from: container, at: directory.appendingPathComponent(filename),
            mirrorsCloud: container is NSPersistentCloudKitContainer,
            loader: cloudLibraryLoader, validateAccount: validateAccount
        )
        return filename
    }

    func setLibraryExcludedFromBackup(_ excluded: Bool) throws {
        for description in container.persistentStoreDescriptions where description.type != NSInMemoryStoreType {
            guard let storeURL = description.url else { continue }
            // Includes SQLite sidecars and Core Data's external binary storage.
            var directory = storeURL.deletingLastPathComponent()
            var values = URLResourceValues()
            values.isExcludedFromBackup = excluded
            try directory.setResourceValues(values)
        }
    }

    /// A clean local store has no CloudKit record mappings. Remote deletion
    /// tombstones must never remove our verified library when sync is enabled later.
    func copyLibraryForLocalStorage() async throws -> String {
        guard isLoaded, let originalURL = container.persistentStoreDescriptions.first?.url else {
            throw CocoaError(.persistentStoreOperation)
        }
        loadState = .loading
        defer { loadState = .loaded }
        if container.viewContext.hasChanges { try container.viewContext.save() }
        let filename = "DeviceLibrary-\(UUID().uuidString).sqlite"
        let local = NSPersistentContainer(name: "progress", managedObjectModel: container.managedObjectModel)
        let description = NSPersistentStoreDescription(url: originalURL.deletingLastPathComponent().appendingPathComponent(filename))
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        local.persistentStoreDescriptions = [description]
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            local.loadPersistentStores { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
        let source = makeBackgroundContext()
        let target = local.newBackgroundContext()
        let ids = try await source.perform {
            let request = NSFetchRequest<NSManagedObjectID>(entityName: "DailyPhoto")
            request.resultType = .managedObjectIDResultType
            return try source.fetch(request)
        }
        for id in ids {
            try Task.checkCancellation()
            let attributes: [String: PhotoLibraryAttribute] = try await source.perform {
                let photo = try source.existingObject(with: id)
                defer { source.refresh(photo, mergeChanges: false) }
                return try photo.entity.attributesByName.reduce(into: [:]) { result, attribute in
                    if let value = photo.value(forKey: attribute.key) {
                        result[attribute.key] = try PhotoLibraryAttribute(value: value, type: attribute.value.attributeType)
                    }
                }
            }
            try await target.perform {
                let photo = DailyPhoto(context: target)
                for (key, attribute) in attributes { photo.setValue(attribute.value, forKey: key) }
                try target.save()
                target.reset()
            }
        }
        try Task.checkCancellation()
        let count = try await target.perform { try target.count(for: DailyPhoto.fetchRequest()) }
        guard count == ids.count else { throw CocoaError(.persistentStoreSave) }
        for store in local.persistentStoreCoordinator.persistentStores { try local.persistentStoreCoordinator.remove(store) }
        return filename
    }

    @MainActor
    func rebuildPersistentStore() async throws {
        let coordinator = container.persistentStoreCoordinator
        let descriptions = container.persistentStoreDescriptions
        let viewContext = container.viewContext

        if viewContext.hasChanges {
            try viewContext.save()
        }
        viewContext.reset()

        let stores = coordinator.persistentStores
        for store in stores {
            guard let storeURL = store.url else { continue }
            try coordinator.remove(store)
            try coordinator.destroyPersistentStore(at: storeURL, type: .sqlite)
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var remaining = descriptions.count
            var firstError: Error?

            container.loadPersistentStores { _, error in
                if let error, firstError == nil {
                    firstError = error
                }

                remaining -= 1
                guard remaining == 0 else { return }

                if let firstError {
                    continuation.resume(throwing: firstError)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
    }

    @MainActor
    var cloudSyncMonitor: CloudSyncMonitor {
        CloudSyncMonitor.shared
    }
}
