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

    init(inMemory: Bool = false) {
        let processInfo = ProcessInfo.processInfo
        let shouldUseInMemory = inMemory
            || processInfo.arguments.contains("UI_TEST_IN_MEMORY_STORE")
            || processInfo.environment["UI_TEST_IN_MEMORY_STORE"] == "1"
        container = if shouldUseInMemory {
            NSPersistentContainer(name: "progress", managedObjectModel: Self.managedObjectModel)
        } else {
            NSPersistentCloudKitContainer(name: "progress", managedObjectModel: Self.managedObjectModel)
        }
        for description in container.persistentStoreDescriptions {
            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        }
        if shouldUseInMemory {
            container.persistentStoreDescriptions.first!.type = NSInMemoryStoreType
        }
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
        guard !isLoadingStore, container.persistentStoreCoordinator.persistentStores.isEmpty else {
            return
        }
        loadPersistentStores()
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
            logger.log("persistent-store-load-succeeded")
            loadState = .loaded
        }
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
