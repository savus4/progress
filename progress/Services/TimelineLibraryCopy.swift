import CoreData
import Foundation

/// Copies metadata separately from photos: CloudKit may import either first.
/// Logical IDs coalesce duplicate rows without requiring CloudKit uniqueness constraints.
enum TimelineLibraryCopy {
    static func merge(from source: NSManagedObjectContext, to target: NSManagedObjectContext,
                      restoringKeptCloudTimelines: Bool = false) async throws {
        let locallyRemoved = try await source.perform {
            Set(try source.fetch(Timeline.fetchRequest()).filter { $0.localDeletedAt != nil }.compactMap(\.id))
        }
        let ids = try await source.perform {
            let request = NSFetchRequest<NSManagedObjectID>(entityName: "Timeline")
            request.resultType = .managedObjectIDResultType
            return try source.fetch(request)
        }
        for objectID in ids {
            try Task.checkCancellation()
            let (id, attributes) = try await source.perform {
                let row = try source.existingObject(with: objectID)
                defer { source.refresh(row, mergeChanges: false) }
                guard let id = row.value(forKey: "id") as? UUID else {
                    throw CocoaError(.validationMissingMandatoryProperty)
                }
                let attributes = try row.entity.attributesByName.reduce(into: [String: PhotoLibraryAttribute]()) { values, entry in
                    if let value = row.value(forKey: entry.key) {
                        values[entry.key] = try PhotoLibraryAttribute(value: value, type: entry.value.attributeType)
                    }
                }
                return (id, attributes)
            }
            // Skip every duplicate for a locally removed owner, including stale active rows.
            if restoringKeptCloudTimelines, locallyRemoved.contains(id), attributes["deletedAt"] == nil { continue }
            try await target.perform {
                let request = Timeline.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", id as NSUUID)
                let rows = try target.fetch(request)
                let incomingDate = attributes["modifiedAt"]?.value as? Date ?? .distantPast
                let incomingRank = attributes["deletedAt"] != nil ? 2 : (attributes["localDeletedAt"] != nil ? 1 : 0)
                let targetRank = rows.contains { $0.deletedAt != nil } ? 2 : (rows.contains { $0.localDeletedAt != nil } ? 1 : 0)
                // Synced deletion dominates local removal, which dominates stale active rows.
                if targetRank > incomingRank { return }
                let newestMetadata = rows.map { $0.modifiedAt ?? .distantPast }.max()
                let copiesMetadata = rows.isEmpty || targetRank < incomingRank
                    || (newestMetadata ?? .distantPast) < incomingDate
                var preference = TimelineStore.livePhotoPreference(in: rows)
                if let enabled = attributes["livePhotoCaptureEnabled"]?.value as? Bool {
                    let incoming = TimelineLivePhotoPreference(isEnabled: enabled,
                        modifiedAt: attributes["livePhotoPreferenceModifiedAt"]?.value as? Date)
                    if incoming.supersedes(preference) { preference = incoming }
                }
                if max(targetRank, incomingRank) > 0 { preference = nil }
                var cameraPreference = TimelineStore.cameraPreference(in: rows)
                if let raw = attributes["cameraPositionRaw"]?.value as? String,
                   let position = CameraPosition(rawValue: raw) {
                    let incoming = TimelineCameraPreference(position: position,
                        modifiedAt: attributes["cameraPreferenceModifiedAt"]?.value as? Date)
                    if incoming.supersedes(cameraPreference) { cameraPreference = incoming }
                }
                if max(targetRank, incomingRank) > 0 { cameraPreference = nil }
                let destinations = rows.isEmpty ? [Timeline(context: target)] : rows
                for row in destinations {
                    if copiesMetadata {
                        for key in row.entity.attributesByName.keys
                            where key != "livePhotoCaptureEnabled" && key != "livePhotoPreferenceModifiedAt"
                                && key != "cameraPositionRaw" && key != "cameraPreferenceModifiedAt" {
                            row.setValue(attributes[key]?.value, forKey: key)
                        }
                    }
                    let enabled = preference.map { NSNumber(value: $0.isEnabled) }
                    if row.livePhotoCaptureEnabled != enabled { row.livePhotoCaptureEnabled = enabled }
                    if row.livePhotoPreferenceModifiedAt != preference?.modifiedAt {
                        row.livePhotoPreferenceModifiedAt = preference?.modifiedAt
                    }
                    if row.cameraPositionRaw != cameraPreference?.position.rawValue {
                        row.cameraPositionRaw = cameraPreference?.position.rawValue
                    }
                    if row.cameraPreferenceModifiedAt != cameraPreference?.modifiedAt {
                        row.cameraPreferenceModifiedAt = cameraPreference?.modifiedAt
                    }
                }
                if target.hasChanges { try target.save() }
                target.reset()
            }
        }
    }
}
