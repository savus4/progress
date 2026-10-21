import CloudKit
import CoreData
import Foundation
import Testing
@testable import progress

@MainActor
struct PhotoCloudLibraryMergeTests {
    @Test("Re-enabling iCloud restores three cloud photos deleted locally and keeps the new photo",
          arguments: [false, true])
    func localDeletionsDoNotDeleteCloudPhotos(keepOneCloudPhoto: Bool) async throws {
        let cloudIDs = [UUID(), UUID(), UUID()]
        let newID = UUID()
        var imports = 0
        let library = try await PhotoStorageScenarioLibrary(empty: true, cloudLibraryLoader: { target in
            imports += 1
            try await Self.load(target)
            for id in cloudIDs {
                Self.addPhoto(id, to: target.viewContext, location: "Cloud original")
            }
            try target.viewContext.save()
        })
        defer { library.cleanup() }
        let context = library.persistence.container.viewContext
        for id in cloudIDs {
            Self.addPhoto(id, to: context, location: "Cloud original")
            let name = "\(id).heic"
            let bytes = Data("original \(id)".utf8)
            let url = library.root.appendingPathComponent("server").appendingPathComponent(name)
            try bytes.write(to: url)
            library.network.data[name] = bytes
            library.network.urls[name] = url
            library.network.records.insert(CKRecord.ID(recordName: name))
            _ = try library.cloud.stageAssetData(bytes, named: name)
        }
        try context.save()
        let storage = library.coordinator()
        try await storage.beginLocalStorage(removeCloudCopies: false)
        await storage.resumeAndWait()
        try #require(storage.mode == .local)

        // Use the same deletion path as the UI while cloud sync is disabled.
        let service = PhotoStorageService(cloudKitService: library.cloud, remoteAssetDeletionService: library.remoteAssetDeletions)
        for photo in try context.fetch(DailyPhoto.fetchRequest()) {
            if keepOneCloudPhoto, photo.id == cloudIDs[0] {
                photo.locationName = "Edited while local"
                continue
            }
            try await service.deletePhoto(photo.objectID, context: context)
        }
        Self.addPhoto(newID, to: context, location: "New local photo")
        _ = try library.cloud.stageAssetData(Data("new original".utf8), named: "\(newID).heic")
        try context.save()
        let localURL = library.persistence.container.persistentStoreDescriptions.first?.url
        // Also recover cleanup intents written by the previous app version.
        let cloudAssetNames = Set(cloudIDs.map { "\($0).heic" })
        await library.remoteAssetDeletions.enqueueForDeferredProcessing(assetNames: cloudAssetNames)

        try await storage.beginICloudStorage()
        await storage.resumeAndWait()

        try #require(storage.errorMessage == nil, Comment(rawValue: storage.errorMessage ?? ""))
        #expect(storage.mode == .iCloud)
        #expect(imports == 1)
        #expect(library.persistence.container.persistentStoreDescriptions.first?.url != localURL)
        let restored = try context.fetch(DailyPhoto.fetchRequest())
        #expect(restored.count == 4)
        #expect(Set(restored.compactMap(\.id)) == Set(cloudIDs + [newID]))
        if keepOneCloudPhoto {
            #expect(restored.first { $0.id == cloudIDs[0] }?.locationName == "Edited while local")
        }
        #expect(library.network.deleted.isEmpty)
        #expect(library.cloud.uploadStateStore.entry(for: newID)?.state == .pending)
        #expect(library.cloud.stagedAssetURL(named: "\(newID).heic") != nil)
        await library.remoteAssetDeletions.processPendingDeletions(expeditingRetries: true)
        #expect(library.network.deleted.isEmpty)
        #expect(library.network.records.count == 3)
        for name in cloudAssetNames {
            let url = try await library.cloud.loadAssetURL(named: name)
            #expect(try Data(contentsOf: url) == library.network.data[name])
        }

        try await library.reopen()
        #expect(try library.persistence.container.viewContext.count(for: DailyPhoto.fetchRequest()) == 4)
    }

    @Test("A failed cloud import preserves the local source and resumes safely after restart",
          arguments: [false, true])
    func failedImportCanResume(cancelled: Bool) async throws {
        let cloudID = UUID()
        let localID = UUID()
        let state = ImportState()
        let library = try await PhotoStorageScenarioLibrary(empty: true, cloudLibraryLoader: { target in
            try await Self.load(target)
            if state.failsImport {
                if cancelled { throw CancellationError() }
                throw CocoaError(.fileReadUnknown)
            }
            Self.addPhoto(cloudID, to: target.viewContext, location: "Retained cloud photo")
            try target.viewContext.save()
        })
        defer { library.cleanup() }
        try library.modeStore.set(.local)
        Self.addPhoto(localID, to: library.persistence.container.viewContext, location: "Local original")
        _ = try library.cloud.stageAssetData(Data("local original".utf8), named: "\(localID).heic")
        try library.persistence.container.viewContext.save()
        let sourceURL = library.persistence.container.persistentStoreDescriptions.first?.url
        let storage = library.coordinator()
        try await storage.beginICloudStorage()
        await storage.resumeAndWait()

        #expect(storage.mode == .preparingUpload)
        #expect(library.persistence.isLoaded)
        #expect(library.persistence.container.persistentStoreDescriptions.first?.url == sourceURL)
        #expect(library.modeStore.storeFilename == nil)
        #expect(try library.persistence.container.viewContext.count(for: DailyPhoto.fetchRequest()) == 1)
        #expect(library.cloud.stagedAssetURL(named: "\(localID).heic") != nil)
        #expect(library.network.deleted.isEmpty)

        state.failsImport = false
        try await library.reopen()
        let resumed = library.coordinator()
        await resumed.resumeAndWait()
        #expect(resumed.mode == .iCloud)
        #expect(resumed.errorMessage == nil)
        let photos = try library.persistence.container.viewContext.fetch(DailyPhoto.fetchRequest())
        #expect(Set(photos.compactMap(\.id)) == [cloudID, localID])
        #expect(library.cloud.uploadStateStore.entry(for: localID)?.state == .pending)
    }

    @Test("Local single and batch deletions never schedule future cloud cleanup", arguments: [false, true])
    func localDeletionsDoNotQueueAssetRemoval(batch: Bool) async throws {
        let library = try await PhotoStorageScenarioLibrary()
        defer { library.cleanup() }
        library.network.records = Set(library.names.map { CKRecord.ID(recordName: $0) })
        try library.modeStore.set(.local)
        let context = library.persistence.container.viewContext
        let photo = try #require(try context.fetch(DailyPhoto.fetchRequest()).first)
        let service = PhotoStorageService(cloudKitService: library.cloud, remoteAssetDeletionService: library.remoteAssetDeletions)
        if batch { _ = try await service.deletePhotos([photo.objectID], context: context) }
        else { try await service.deletePhoto(photo.objectID, context: context) }

        try library.modeStore.set(.iCloud)
        await library.remoteAssetDeletions.processPendingDeletions(expeditingRetries: true)
        #expect(library.network.deleted.isEmpty)
        #expect(library.network.records.count == 3)
    }

    @MainActor private final class ImportState {
        var failsImport = true
    }

    static func addPhoto(_ id: UUID, to context: NSManagedObjectContext, location: String) {
        let photo = DailyPhoto(context: context)
        photo.id = id
        photo.captureDate = Date(timeIntervalSince1970: 1_700_000_000)
        photo.createdAt = photo.captureDate
        photo.modifiedAt = photo.captureDate
        photo.fullImageAssetName = "\(id).heic"
        photo.locationName = location
    }

    static func load(_ container: NSPersistentContainer) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            container.loadPersistentStores { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
}
