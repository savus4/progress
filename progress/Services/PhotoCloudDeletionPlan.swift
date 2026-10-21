import CloudKit
import Foundation

nonisolated struct PhotoCloudDeletionPlan: Codable, Sendable {
    struct Record: Codable, Hashable, Sendable {
        let name: String
        let zone: String
        let owner: String

        init(_ id: CKRecord.ID) {
            name = id.recordName
            zone = id.zoneID.zoneName
            owner = id.zoneID.ownerName
        }

        var id: CKRecord.ID { CKRecord.ID(recordName: name, zoneID: CKRecordZone.ID(zoneName: zone, ownerName: owner)) }
    }

    let accountID: String
    let metadataRecords: [Record]
    let assetNames: Set<String>
}
