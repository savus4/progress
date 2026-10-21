import CloudKit
import CoreData
import Foundation
import Testing
@testable import progress

/// Core Data chooses its own CloudKit zone. This test uses a temporary SQLite
/// library and edits/deletes only the single synthetic UUID it creates. Imported
/// rows belonging to the account are never edited or included in a deletion plan.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["RUN_LIVE_CLOUDKIT_TESTS"] == "1"))
@MainActor
struct PhotoStorageLiveMirroringTests {
    @Test("Real Core Data export stops locally and resumes with the same record identity", .timeLimit(.minutes(5)))
    func mirroringSwitch() async throws {
        try #require(StorageTestConfiguration.isIsolatedHost)
        let container = CKContainer(identifier: CloudKitConfiguration.containerIdentifier)
        let accountStatus = try await container.accountStatus()
        try #require(accountStatus == .available, "CloudKit account status: \(accountStatus.rawValue)")
        let database = container.privateCloudDatabase
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StorageMirroring-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let preference = PhotoStorageModeStore(storageURL: root.appendingPathComponent("preference/mode.json"))
        let persistence = PersistenceController(storageModeStore: preference, storeURL: root.appendingPathComponent("library.sqlite"))
        var ownedRecordID: CKRecord.ID?
        var ownedObjectID: NSManagedObjectID?
        do {
            try await PhotoStorageScenarioLibrary.waitUntilLoaded(persistence)
            let mirror = try #require(persistence.container as? NSPersistentCloudKitContainer)
            try #require(persistence.container.persistentStoreDescriptions.first?.cloudKitContainerOptions != nil)
            let photoID = UUID()
            let photo = DailyPhoto(context: mirror.viewContext)
            photo.id = photoID
            photo.createdAt = Date(); photo.captureDate = Date(); photo.modifiedAt = Date()
            photo.locationName = "StorageTests initial \(photoID)"
            photo.fullImageAssetName = "StorageTests-\(photoID)-metadata-only.png"
            try mirror.viewContext.save()
            ownedObjectID = photo.objectID
            let initialLocation = try #require(photo.locationName)
            try await eventually("Initial synthetic metadata was not exported to iCloud") {
                if let id = mirror.recordID(for: photo.objectID) { ownedRecordID = id }
                guard let id = ownedRecordID, let remote = try await recordIfPresent(id, in: database) else { return false }
                return remote["CD_locationName"] as? String == initialLocation
            }
            let remoteID = try #require(ownedRecordID)
            let objectID = try #require(ownedObjectID)
            try preference.set(.local)
            try await persistence.reloadCloudConfiguration()
            #expect(mirror.persistentStoreDescriptions.first?.cloudKitContainerOptions == nil)
            let local = try #require(try mirror.viewContext.existingObject(with: objectID) as? DailyPhoto)
            #expect(local.id == photoID)
            let editedLocation = "StorageTests edited locally \(photoID)"
            local.locationName = editedLocation
            local.modifiedAt = Date()
            try mirror.viewContext.save()
            // Observe the server during a bounded interval, then explicitly prove
            // that this exact pending edit exports after reattaching mirroring.
            let end = ContinuousClock.now.advanced(by: .seconds(10))
            repeat {
                let remote = try #require(try await recordIfPresent(remoteID, in: database))
                #expect(remote["CD_locationName"] as? String == initialLocation)
                try await Task.sleep(for: .seconds(1))
            } while ContinuousClock.now < end
            try preference.set(.iCloud)
            try await persistence.reloadCloudConfiguration()
            #expect(mirror.persistentStoreDescriptions.first?.cloudKitContainerOptions != nil)
            try await eventually("The pending local edit did not export after iCloud was re-enabled") {
                guard let remote = try await recordIfPresent(remoteID, in: database) else { return false }
                return remote["CD_locationName"] as? String == editedLocation
            }
            let reopened = try #require(try mirror.viewContext.existingObject(with: objectID) as? DailyPhoto)
            #expect(reopened.id == photoID)
            #expect(mirror.recordID(for: reopened.objectID) == remoteID)
            let request = DailyPhoto.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", photoID as NSUUID)
            #expect(try mirror.viewContext.count(for: request) == 1)
        } catch {
            if ownedRecordID == nil, let id = ownedObjectID {
                ownedRecordID = (persistence.container as? NSPersistentCloudKitContainer)?.recordID(for: id)
            }
            try await cleanup(persistence, root: root, ownedRecordID: ownedRecordID, database: database)
            throw error
        }
        try await cleanup(persistence, root: root, ownedRecordID: ownedRecordID, database: database)
    }

    private func eventually(_ failure: String, condition: @MainActor () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(100))
        while ContinuousClock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .seconds(1))
        }
        Issue.record(Comment(rawValue: failure))
        throw PhotoStorageMigrationError.attention(failure)
    }

    private func recordIfPresent(_ id: CKRecord.ID, in database: CKDatabase) async throws -> CKRecord? {
        do { return try await database.record(for: id) }
        catch let error as CKError where error.code == .unknownItem { return nil }
    }

    private func cleanup(_ persistence: PersistenceController, root: URL, ownedRecordID: CKRecord.ID?, database: CKDatabase) async throws {
        // Stop the exporter before deleting our exact record, preventing a late
        // export from recreating it. No other CloudKit IDs are ever deleted.
        persistence.container.viewContext.reset()
        for store in persistence.container.persistentStoreCoordinator.persistentStores {
            try persistence.container.persistentStoreCoordinator.remove(store)
        }
        if let id = ownedRecordID {
            do { _ = try await database.deleteRecord(withID: id) }
            catch let error as CKError where error.code == .unknownItem { }
        }
        try FileManager.default.removeItem(at: root)
    }
}
