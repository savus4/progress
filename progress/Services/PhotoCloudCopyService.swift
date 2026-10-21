import CloudKit
import Foundation

@MainActor
final class PhotoCloudCopyService {
    private let container = CKContainer(identifier: CloudKitConfiguration.containerIdentifier)
    private var database: CKDatabase { container.privateCloudDatabase }
    private let accountIDProvider: (@MainActor () async throws -> String)?
    private let recordIDsProvider: (@MainActor () async throws -> Set<CKRecord.ID>)?
    private let deleteRecords: (@MainActor ([CKRecord.ID]) async throws -> Void)?
    private let existingRecords: (@MainActor ([CKRecord.ID]) async throws -> Set<CKRecord.ID>)?
    private let recordZoneID: CKRecordZone.ID?
    private let recordPageSize: Int?

    init(accountIDProvider: (@MainActor () async throws -> String)? = nil,
         recordIDsProvider: (@MainActor () async throws -> Set<CKRecord.ID>)? = nil,
         deleteRecords: (@MainActor ([CKRecord.ID]) async throws -> Void)? = nil,
         existingRecords: (@MainActor ([CKRecord.ID]) async throws -> Set<CKRecord.ID>)? = nil,
         recordZoneID: CKRecordZone.ID? = nil, recordPageSize: Int? = nil) {
        self.accountIDProvider = accountIDProvider
        self.recordIDsProvider = recordIDsProvider
        self.deleteRecords = deleteRecords
        self.existingRecords = existingRecords
        self.recordZoneID = recordZoneID
        self.recordPageSize = recordPageSize
    }

    func accountID() async throws -> String {
        if let accountIDProvider { return try await accountIDProvider() }
        guard try await container.accountStatus() == .available else {
            throw PhotoStorageMigrationError.attention("Sign in to iCloud and enable access for Work in Progress first.")
        }
        return try await container.userRecordID().recordName
    }

    /// Check the server's library, including pages not yet imported by Core Data.
    /// Unknown records block deletion; they must be synced and downloaded first.
    func validate(_ plan: PhotoCloudDeletionPlan) async throws {
        guard try await accountID() == plan.accountID else { throw PhotoStorageMigrationError.accountChanged }
        let remote = try await photoRecordIDs()
        let known = Set(plan.metadataRecords.map(\.id)).union(plan.assetNames.map { assetRecordID(named: $0) })
        guard remote.isSubset(of: known) else {
            throw PhotoStorageMigrationError.attention("iCloud has photos that aren’t in this device’s library yet. Keep iCloud copies, let the library finish syncing on this device, then try again. No unknown photos were deleted.")
        }
    }

    /// Called only with a durable plan, from the detached local store, AFTER all
    /// originals have been verified. Every deletion result and final absence is checked.
    func remove(_ plan: PhotoCloudDeletionPlan) async throws {
        try await validate(plan)
        let ids = Array(Set(plan.metadataRecords.map(\.id)).union(plan.assetNames.map { assetRecordID(named: $0) }))
        // A scoped instance must never accept a plan that targets another zone.
        if let recordZoneID, !ids.allSatisfy({ $0.zoneID == recordZoneID }) {
            throw PhotoStorageMigrationError.attention("The deletion plan contains records outside this library’s CloudKit zone.")
        }
        for offset in stride(from: 0, to: ids.count, by: 100) {
            try Task.checkCancellation()
            guard try await accountID() == plan.accountID else { throw PhotoStorageMigrationError.accountChanged }
            let batch = Array(ids[offset..<min(offset + 100, ids.count)])
            if let deleteRecords { try await deleteRecords(batch); continue }
            let result = try await database.modifyRecords(saving: [], deleting: batch, atomically: false)
            for id in batch {
                guard let outcome = result.deleteResults[id] else { throw CloudKitError.uploadFailed }
                do { _ = try outcome.get() }
                catch where Self.isAbsent(error) { }
            }
        }
        // Queries may briefly contain deleted entries; resolve each returned ID
        // directly as well as checking every target from the original plan.
        let remaining = Array(try await photoRecordIDs().union(ids))
        for offset in stride(from: 0, to: remaining.count, by: 100) {
            try Task.checkCancellation()
            let batch = Array(remaining[offset..<min(offset + 100, remaining.count)])
            if let existingRecords {
                guard try await existingRecords(batch).isEmpty else {
                    throw PhotoStorageMigrationError.attention("Some iCloud copies still exist. Deletion will be checked again. Your local originals are safe.")
                }
                continue
            }
            let records = try await database.records(for: batch, desiredKeys: [])
            for id in batch {
                guard let result = records[id] else { throw CloudKitError.downloadFailed }
                do {
                    _ = try result.get()
                    throw PhotoStorageMigrationError.attention("Some iCloud copies still exist. Deletion will be checked again. Your local originals are safe.")
                } catch where Self.isAbsent(error) { }
            }
        }
        guard try await accountID() == plan.accountID else { throw PhotoStorageMigrationError.accountChanged }
    }

    /// Read-only inventory also lets integration tests verify the production
    /// schema/index prerequisite without targeting the user's records for deletion.
    func photoRecordIDs() async throws -> Set<CKRecord.ID> {
        if let recordIDsProvider { return try await recordIDsProvider() }
        var result = Set<CKRecord.ID>()
        let zones = if let recordZoneID { [CKRecordZone(zoneID: recordZoneID)] }
            else { try await database.allRecordZones() }
        for zone in zones where zone.zoneID != CKRecordZone.default().zoneID {
            var token: CKServerChangeToken?
            while true {
                let changes = try await database.recordZoneChanges(inZoneWith: zone.zoneID, since: token, desiredKeys: [], resultsLimit: recordPageSize)
                for (_, modification) in changes.modificationResultsByID {
                    let record = try modification.get().record
                    if record.recordType == "CD_DailyPhoto" || (recordZoneID != nil && record.recordType == "PhotoAsset") {
                        result.insert(record.recordID)
                    }
                }
                for deletion in changes.deletions { result.remove(deletion.recordID) }
                token = changes.changeToken
                if !changes.moreComing { break }
                try Task.checkCancellation()
            }
        }
        if recordZoneID != nil { return result }
        do {
            var page = try await database.records(matching: CKQuery(recordType: "PhotoAsset", predicate: NSPredicate(value: true)), desiredKeys: [])
            while true {
                for (id, record) in page.matchResults { _ = try record.get(); result.insert(id) }
                guard let cursor = page.queryCursor else { break }
                try Task.checkCancellation()
                page = try await database.records(continuingMatchFrom: cursor, desiredKeys: [])
            }
        } catch where Self.isAbsent(error) {
            // A new iCloud account may not have a PhotoAsset record type yet.
        }
        return result
    }

    private static func isAbsent(_ error: Error) -> Bool {
        guard let error = error as? CKError else { return false }
        return error.code == .unknownItem || error.code == .zoneNotFound
    }

    private func assetRecordID(named name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: recordZoneID ?? CKRecordZone.default().zoneID)
    }
}
