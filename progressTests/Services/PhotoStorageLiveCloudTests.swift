import CloudKit
import CoreData
import Foundation
import Testing
@testable import progress

/// Explicitly opt in on a signed-in simulator. All asset writes and deletions are
/// confined to a newly created zone; existing application records are never targets.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["RUN_LIVE_CLOUDKIT_TESTS"] == "1"))
@MainActor
struct PhotoStorageLiveCloudTests {
    @Test("The production library enumeration and PhotoAsset query index are available")
    func productionEnumerationIsReadable() async throws {
        try #require(StorageTestConfiguration.isIsolatedHost)
        let copies = PhotoCloudCopyService()
        _ = try await copies.accountID()
        // This is deliberately read-only. Existing account records are neither
        // downloaded nor passed to remove(_:), even when the account is nonempty.
        _ = try await copies.photoRecordIDs()
    }

    @Test("Real private assets survive cloud → device → cloud with all resource bytes", arguments: [false, true])
    func cloudDeviceRoundTrip(removeCloudCopies: Bool) async throws {
        try await withLibrary { library, database in
            try await library.uploadOriginals()
            for name in library.names {
                let metadata = try await library.cloud.offlineAssetMetadata(named: name, allowsCellularAccess: true)
                #expect(metadata.byteCount == Int64(try #require(library.network.data[name]).count))
                #expect(metadata.checksum == (try library.network.metadata(name)).checksum)
            }
            try await library.makeRemoteOnly()
            let storage = library.coordinator()
            try await storage.beginLocalStorage(removeCloudCopies: removeCloudCopies)
            await storage.resumeAndWait()
            try #require(storage.mode == .local, Comment(rawValue: storage.errorMessage ?? "Switch did not complete"))
            #expect(storage.errorMessage == nil)
            try await library.assertLocalOriginals()
            for name in library.names {
                let id = CKRecord.ID(recordName: name, zoneID: try #require(library.zoneID))
                #expect(try await exists(id, in: database) == !removeCloudCopies)
            }
            // The local read must succeed after the server copy is gone, with the
            // same files available after reopening every persistent component.
            try await library.reopen()
            for name in library.names {
                let url = try await library.cloud.loadAssetURL(named: name)
                #expect(try Data(contentsOf: url) == library.network.data[name])
            }
            let resumed = library.coordinator()
            try await resumed.beginICloudStorage()
            await resumed.resumeAndWait()
            try #require(resumed.mode == .iCloud, Comment(rawValue: resumed.errorMessage ?? "Upload preparation did not complete"))
            let uploader = library.uploader()
            #expect(try await uploader.uploadNextPendingPhotoForTesting(in: library.persistence.makeBackgroundContext()))
            #expect(library.cloud.uploadStateStore.entry(for: library.photoID)?.state == .uploaded)
            for name in library.names {
                let record = try await database.record(for: CKRecord.ID(recordName: name, zoneID: try #require(library.zoneID)))
                let asset = try #require(record["fileAsset"] as? CKAsset)
                #expect(try Data(contentsOf: #require(asset.fileURL)) == library.network.data[name])
            }
            let rows = try library.persistence.container.viewContext.fetch(DailyPhoto.fetchRequest())
            #expect(rows.count == 1)
            #expect(rows.first?.id == library.photoID)
        }
    }

    @Test("Real paginated enumeration rejects unknown photos and verifies complete removal")
    func paginatedDeletion() async throws {
        try await withLibrary { library, database in
            try await library.uploadOriginals()
            let zone = try #require(library.zoneID)
            let account = try await library.copies().accountID()
            let unknown = CKRecord(recordType: "PhotoAsset", recordID: CKRecord.ID(recordName: "StorageTests-unknown-\(UUID())", zoneID: zone))
            _ = try await database.save(unknown)
            let copies = library.copies(pageSize: 1)
            let plan = PhotoCloudDeletionPlan(accountID: account, metadataRecords: [], assetNames: library.names)
            await #expect(throws: PhotoStorageMigrationError.self) { try await copies.validate(plan) }
            for name in library.names { #expect(try await exists(CKRecord.ID(recordName: name, zoneID: zone), in: database)) }

            // This metadata record models the second CloudKit path (Core Data).
            let metadata = CKRecord(recordType: "CD_DailyPhoto", recordID: CKRecord.ID(recordName: "StorageTests-metadata-\(UUID())", zoneID: zone))
            _ = try await database.save(metadata)
            _ = try await database.deleteRecord(withID: unknown.recordID)
            let completePlan = PhotoCloudDeletionPlan(accountID: account, metadataRecords: [.init(metadata.recordID)], assetNames: library.names)
            try await copies.validate(completePlan)
            try await copies.remove(completePlan)
            try await copies.remove(completePlan)
            #expect(try await exists(metadata.recordID, in: database) == false)
            for name in library.names { #expect(try await exists(CKRecord.ID(recordName: name, zoneID: zone), in: database) == false) }
        }
    }

    @Test("A scoped deletion client rejects records from another zone")
    func deletionCannotEscapeTestZone() async throws {
        try await withLibrary { library, database in
            try await library.uploadOriginals()
            let copies = library.copies()
            let account = try await copies.accountID()
            let outside = CKRecord.ID(recordName: "never-delete-\(UUID())")
            let plan = PhotoCloudDeletionPlan(accountID: account, metadataRecords: [.init(outside)], assetNames: library.names)
            await #expect(throws: PhotoStorageMigrationError.self) { try await copies.remove(plan) }
            for name in library.names {
                #expect(try await exists(CKRecord.ID(recordName: name, zoneID: #require(library.zoneID)), in: database))
            }
        }
    }

    private func withLibrary(_ body: @MainActor (PhotoStorageScenarioLibrary, CKDatabase) async throws -> Void) async throws {
        try #require(StorageTestConfiguration.isIsolatedHost, "Live tests require STORAGE_TEST_HOST=1 to disable normal app background services.")
        let container = CKContainer(identifier: CloudKitConfiguration.containerIdentifier)
        let accountStatus = try await container.accountStatus()
        try #require(accountStatus == .available, "CloudKit account status: \(accountStatus.rawValue). Sign into iCloud on the iPhone 18 Pro simulator first.")
        let database = container.privateCloudDatabase
        let zone = CKRecordZone(zoneName: "StorageTests-\(UUID())")
        _ = try await database.save(zone)
        do {
            let library = try await PhotoStorageScenarioLibrary(zoneID: zone.zoneID)
            defer { library.cleanup() }
            try await body(library, database)
        } catch {
            do { _ = try await database.deleteRecordZone(withID: zone.zoneID) }
            catch { Issue.record(error, "Could not remove this test's isolated CloudKit zone: \(zone.zoneID.zoneName)") }
            throw error
        }
        _ = try await database.deleteRecordZone(withID: zone.zoneID)
    }

    private func exists(_ id: CKRecord.ID, in database: CKDatabase) async throws -> Bool {
        do { _ = try await database.record(for: id); return true }
        catch let error as CKError where error.code == .unknownItem { return false }
    }
}
