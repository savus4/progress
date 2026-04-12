//
//  Persistence.swift
//  progress
//
//  Created by Simon Riepl on 19.02.26.
//

import CoreData
import UIKit

struct PersistenceController {
    static let shared = PersistenceController()

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
            let nsError = error as NSError
            fatalError("Unresolved error \(nsError), \(nsError.userInfo)")
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

    let container: NSPersistentCloudKitContainer

    init(inMemory: Bool = false) {
        let shouldUseInMemory = inMemory || ProcessInfo.processInfo.arguments.contains("UI_TEST_IN_MEMORY_STORE")
        container = NSPersistentCloudKitContainer(name: "progress")
        for description in container.persistentStoreDescriptions {
            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        }
        if shouldUseInMemory {
            container.persistentStoreDescriptions.first!.url = URL(fileURLWithPath: "/dev/null")
        }
        container.loadPersistentStores(completionHandler: { (storeDescription, error) in
            if let error = error as NSError? {
                // Replace this implementation with code to handle the error appropriately.
                // fatalError() causes the application to generate a crash log and terminate. You should not use this function in a shipping application, although it may be useful during development.

                /*
                 Typical reasons for an error here include:
                 * The parent directory does not exist, cannot be created, or disallows writing.
                 * The persistent store is not accessible, due to permissions or data protection when the device is locked.
                 * The device is out of space.
                 * The store could not be migrated to the current model version.
                 Check the error message to determine what the actual problem was.
                 */
                fatalError("Unresolved error \(error), \(error.userInfo)")
            }
        })
        container.viewContext.name = "ViewContext"
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        container.viewContext.automaticallyMergesChangesFromParent = true
    }

    func makeBackgroundContext() -> NSManagedObjectContext {
        let context = container.newBackgroundContext()
        context.name = "BackgroundContext"
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
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
