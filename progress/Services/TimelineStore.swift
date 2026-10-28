import CoreData
import Foundation

/// Metadata is optional for the default timeline; upgrading never seeds duplicate
/// default rows on offline devices. Photos use the logical UUID, not a row identity.
enum TimelineStore {
    nonisolated static let maxNameLength = 80

    static func snapshots(in context: NSManagedObjectContext) async throws -> [TimelineSnapshot] {
        try await state(in: context).timelines
    }

    static func state(in context: NSManagedObjectContext) async throws -> TimelineLibraryState {
        try await context.perform { try libraryState(in: context) }
    }

    nonisolated static func isNameInUse(_ name: String, among timelines: [TimelineSnapshot], excluding id: UUID? = nil) -> Bool {
        let key = nameKey(name)
        return timelines.contains { $0.id != id && nameKey($0.name) == key }
    }

    /// Offline devices can independently choose the same name. Keep both owners
    /// and persist a deterministic, available suffix when their metadata merges.
    static func resolveNameConflicts(in context: NSManagedObjectContext) async throws {
        guard !PhotoStorageModeStore.shared.mode.isMigrating else { return }
        try await context.perform {
            let timelines = try libraryState(in: context).timelines
            var occupied = Set(timelines.map { nameKey($0.name) })
            var seen = Set<String>()
            var renamed: [UUID: String] = [:]
            for timeline in timelines {
                guard !seen.insert(nameKey(timeline.name)).inserted else { continue }
                var number = 2
                var candidate: String
                repeat {
                    let suffix = " (\(number))"
                    candidate = String(timeline.name.prefix(maxNameLength - suffix.count)) + suffix
                    number += 1
                } while !occupied.insert(nameKey(candidate)).inserted
                renamed[timeline.id] = candidate
            }
            guard !renamed.isEmpty else { return }
            let rows = try context.fetch(Timeline.fetchRequest()).filter { row in
                row.id.map { renamed[$0] != nil } ?? false
            }
            let originals = rows.map { ($0, $0.name, $0.modifiedAt) }
            let now = Date()
            for row in rows {
                if let id = row.id { row.name = renamed[id]; row.modifiedAt = now }
            }
            do { try context.save() }
            catch {
                for (row, name, date) in originals { row.name = name; row.modifiedAt = date }
                throw error
            }
        }
    }

    nonisolated static func libraryState(in context: NSManagedObjectContext) throws -> TimelineLibraryState {
        var byID: [UUID: TimelineSnapshot] = [:]
        var deletedIDs = Set<UUID>()
        var preferences: [UUID: TimelineLivePhotoPreference] = [:]
        var cameraPreferences: [UUID: TimelineCameraPreference] = [:]
        for timeline in try context.fetch(Timeline.fetchRequest()) {
            guard let id = timeline.id else { continue }
            if timeline.deletedAt != nil || timeline.localDeletedAt != nil { deletedIDs.insert(id) }
            if let preference = timeline.livePhotoPreference, preference.supersedes(preferences[id]) {
                preferences[id] = preference
            }
            if let preference = timeline.cameraPreference, preference.supersedes(cameraPreferences[id]) {
                cameraPreferences[id] = preference
            }
            let snapshot = TimelineSnapshot(
                id: id, name: timeline.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                    ?? (id == TimelineIdentity.defaultID ? TimelineIdentity.defaultName : "Timeline"),
                createdAt: timeline.createdAt, modifiedAt: timeline.modifiedAt
            )
            if let existing = byID[id] {
                let previousDate = existing.modifiedAt ?? .distantPast
                let incomingDate = snapshot.modifiedAt ?? .distantPast
                if previousDate > incomingDate || (previousDate == incomingDate && existing.name >= snapshot.name) { continue }
            }
            byID[id] = snapshot
        }
        for (id, metadata) in byID {
            byID[id] = TimelineSnapshot(id: id, name: metadata.name, createdAt: metadata.createdAt,
                                        modifiedAt: metadata.modifiedAt, livePhotoPreference: preferences[id],
                                        cameraPreference: cameraPreferences[id])
        }
        if byID[TimelineIdentity.defaultID] == nil, !deletedIDs.contains(TimelineIdentity.defaultID) {
            byID[TimelineIdentity.defaultID] = TimelineSnapshot(
                id: TimelineIdentity.defaultID, name: TimelineIdentity.defaultName, createdAt: nil, modifiedAt: nil
            )
        }
        // A tombstone always wins over a stale duplicate or a rename from offline devices.
        let active = byID.values.filter { !deletedIDs.contains($0.id) }.sorted {
            if $0.id == $1.id { return false }
            if $0.id == TimelineIdentity.defaultID { return true }
            if $1.id == TimelineIdentity.defaultID { return false }
            if $0.createdAt != $1.createdAt { return ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
            return $0.id.uuidString < $1.id.uuidString
        }
        return TimelineLibraryState(timelines: active, deletedIDs: deletedIDs)
    }

    nonisolated static func validateOwner(_ id: UUID, in context: NSManagedObjectContext) throws {
        let request = Timeline.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@ AND (deletedAt != nil OR localDeletedAt != nil)", id as NSUUID)
        request.fetchLimit = 1
        guard try context.count(for: request) == 0 else { throw TimelineOperationError.deleted }
    }

    static func markDeleted(id: UUID, in context: NSManagedObjectContext,
                            storageMode: PhotoStorageMode = PhotoStorageModeStore.shared.mode) async throws {
        try ensureLibraryAllowsChanges()
        guard !storageMode.isMigrating else { throw PhotoStorageMigrationError.attention("Let the photo storage switch finish before changing timelines.") }
        try await context.perform {
            let state = try libraryState(in: context)
            if state.deletedIDs.contains(id) { return }
            guard state.timelines.contains(where: { $0.id == id }) else { throw TimelineOperationError.deleted }
            guard state.timelines.count > 1 else { throw TimelineOperationError.lastTimeline }
            let request = Timeline.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id as NSUUID)
            var rows = try context.fetch(request)
            let originals = rows.map { ($0, $0.name, $0.modifiedAt, $0.deletedAt, $0.localDeletedAt, $0.livePhotoCaptureEnabled, $0.livePhotoPreferenceModifiedAt, $0.cameraPositionRaw, $0.cameraPreferenceModifiedAt) }
            var inserted: Timeline?
            if rows.isEmpty {
                let row = Timeline(context: context)
                row.id = id
                row.name = state.timelines.first { $0.id == id }?.name
                row.createdAt = Date()
                rows = [row]
                inserted = row
            }
            let now = Date()
            for row in rows {
                row.name = nil
                row.livePhotoCaptureEnabled = nil
                row.livePhotoPreferenceModifiedAt = nil
                row.cameraPositionRaw = nil
                row.cameraPreferenceModifiedAt = nil
                row.deletedAt = storageMode.allowsCloudWrites ? now : nil
                row.localDeletedAt = storageMode.allowsCloudWrites ? nil : now
                row.modifiedAt = now
            }
            do { try context.save() }
            catch {
                if let inserted { context.delete(inserted) }
                for (row, name, modifiedAt, deletedAt, localDeletedAt, enabled, preferenceDate, position, cameraDate) in originals {
                    row.name = name; row.modifiedAt = modifiedAt; row.deletedAt = deletedAt; row.localDeletedAt = localDeletedAt
                    row.livePhotoCaptureEnabled = enabled; row.livePhotoPreferenceModifiedAt = preferenceDate
                    row.cameraPositionRaw = position; row.cameraPreferenceModifiedAt = cameraDate
                }
                throw error
            }
        }
    }

    static func normalizeTombstones(in context: NSManagedObjectContext) async throws {
        try await context.perform {
            let rows = try context.fetch(Timeline.fetchRequest())
            var permanent: [UUID: Date] = [:]
            var local: [UUID: Date] = [:]
            for row in rows {
                guard let id = row.id else { continue }
                if let date = row.deletedAt { permanent[id] = max(permanent[id] ?? .distantPast, date) }
                if let date = row.localDeletedAt { local[id] = max(local[id] ?? .distantPast, date) }
            }
            var changed = false
            for row in rows {
                guard let id = row.id, permanent[id] != nil || local[id] != nil else { continue }
                let localDate = permanent[id] == nil ? local[id] : nil
                // Permanent sync deletion dominates local removal and stale renames.
                if row.name != nil { row.name = nil; changed = true }
                if row.livePhotoCaptureEnabled != nil { row.livePhotoCaptureEnabled = nil; changed = true }
                if row.livePhotoPreferenceModifiedAt != nil { row.livePhotoPreferenceModifiedAt = nil; changed = true }
                if row.cameraPositionRaw != nil { row.cameraPositionRaw = nil; changed = true }
                if row.cameraPreferenceModifiedAt != nil { row.cameraPreferenceModifiedAt = nil; changed = true }
                if row.deletedAt != permanent[id] { row.deletedAt = permanent[id]; changed = true }
                if row.localDeletedAt != localDate { row.localDeletedAt = localDate; changed = true }
            }
            if changed { try context.save() }
        }
    }

    static func ensureAvailableTimeline(in context: NSManagedObjectContext) async throws {
        try await context.perform {
            let state = try libraryState(in: context)
            guard state.timelines.isEmpty else { return }
            let row = Timeline(context: context)
            row.id = TimelineIdentity.recoveryID(afterDeleting: state.deletedIDs)
            row.name = TimelineIdentity.defaultName
            row.createdAt = Date()
            row.modifiedAt = row.createdAt
            do { try context.save() }
            catch { context.delete(row); throw error }
        }
    }

    static func create(name: String, in context: NSManagedObjectContext) async throws -> UUID {
        try ensureLibraryAllowsChanges()
        let name = try validatedName(name)
        return try await context.perform {
            try validateUniqueName(name, in: context)
            let timeline = Timeline(context: context)
            let id = UUID()
            timeline.id = id
            timeline.name = name
            timeline.createdAt = Date()
            timeline.modifiedAt = timeline.createdAt
            do { try context.save() }
            catch { context.delete(timeline); throw error }
            return id
        }
    }

    static func rename(id: UUID, to name: String, in context: NSManagedObjectContext) async throws {
        try ensureLibraryAllowsChanges()
        let name = try validatedName(name)
        try await context.perform {
            try validateOwner(id, in: context)
            try validateUniqueName(name, excluding: id, in: context)
            let request = Timeline.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id as NSUUID)
            var rows = try context.fetch(request)
            let originals = rows.map { ($0, $0.name, $0.modifiedAt) }
            var inserted: Timeline?
            if rows.isEmpty {
                // Also supports metadata arriving after its photos, or a renamed default.
                let timeline = Timeline(context: context)
                timeline.id = id
                timeline.createdAt = Date()
                rows = [timeline]
                inserted = timeline
            }
            let now = Date()
            for row in rows {
                row.name = name
                row.modifiedAt = now
            }
            do { try context.save() }
            catch {
                if let inserted { context.delete(inserted) }
                for (row, oldName, oldDate) in originals {
                    row.name = oldName
                    row.modifiedAt = oldDate
                }
                throw error
            }
        }
    }

    static func setLivePhotoCaptureEnabled(_ enabled: Bool, for id: UUID, in context: NSManagedObjectContext) async throws {
        try await updateLivePhotoPreference(enabled, for: id, in: context, onlyIfUnset: false, changedAt: Date())
    }

    nonisolated static func cameraPreference(in rows: [Timeline]) -> TimelineCameraPreference? {
        rows.compactMap(\.cameraPreference).reduce(nil) { latest, candidate in
            candidate.supersedes(latest) ? candidate : latest
        }
    }

    static func setCameraPosition(_ position: CameraPosition, for id: UUID, in context: NSManagedObjectContext) async throws {
        try ensureLibraryAllowsChanges()
        try await context.perform {
            try validateOwner(id, in: context)
            let request = Timeline.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id as NSUUID)
            var rows = try context.fetch(request)
            guard cameraPreference(in: rows)?.position != position else { return }
            let originals = rows.map { ($0, $0.cameraPositionRaw, $0.cameraPreferenceModifiedAt) }
            var inserted: Timeline?
            if rows.isEmpty {
                let row = Timeline(context: context)
                row.id = id
                row.createdAt = Date()
                rows = [row]
                inserted = row
            }
            let now = Date()
            for row in rows {
                row.cameraPositionRaw = position.rawValue
                row.cameraPreferenceModifiedAt = now
            }
            do { try context.save() }
            catch {
                if let inserted { context.delete(inserted) }
                for (row, position, date) in originals {
                    row.cameraPositionRaw = position; row.cameraPreferenceModifiedAt = date
                }
                throw error
            }
        }
    }

    static func seedLegacyLivePhotoPreference(_ enabled: Bool, in context: NSManagedObjectContext) async throws {
        // A legacy device preference must lose to any explicit synced choice.
        try await updateLivePhotoPreference(enabled, for: TimelineIdentity.defaultID, in: context,
                                           onlyIfUnset: true, changedAt: Date(timeIntervalSince1970: 0))
    }

    nonisolated static func livePhotoPreference(in rows: [Timeline]) -> TimelineLivePhotoPreference? {
        rows.compactMap(\.livePhotoPreference).reduce(nil) { latest, candidate in
            candidate.supersedes(latest) ? candidate : latest
        }
    }

    private static func updateLivePhotoPreference(_ enabled: Bool, for id: UUID, in context: NSManagedObjectContext,
                                                 onlyIfUnset: Bool, changedAt: Date) async throws {
        try ensureLibraryAllowsChanges()
        try await context.perform {
            try validateOwner(id, in: context)
            let request = Timeline.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", id as NSUUID)
            var rows = try context.fetch(request)
            let current = livePhotoPreference(in: rows)
            if onlyIfUnset, current != nil { return }
            if current?.isEnabled == enabled { return }
            let originals = rows.map { ($0, $0.livePhotoCaptureEnabled, $0.livePhotoPreferenceModifiedAt) }
            var inserted: Timeline?
            if rows.isEmpty {
                let row = Timeline(context: context)
                row.id = id
                row.createdAt = Date()
                rows = [row]
                inserted = row
            }
            for row in rows {
                row.livePhotoCaptureEnabled = NSNumber(value: enabled)
                row.livePhotoPreferenceModifiedAt = changedAt
            }
            do { try context.save() }
            catch {
                if let inserted { context.delete(inserted) }
                for (row, enabled, date) in originals {
                    row.livePhotoCaptureEnabled = enabled; row.livePhotoPreferenceModifiedAt = date
                }
                throw error
            }
        }
    }

    private static func validatedName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TimelineNameError.empty }
        guard trimmed.count <= maxNameLength else { throw TimelineNameError.tooLong }
        return trimmed
    }

    nonisolated private static func validateUniqueName(_ name: String, excluding id: UUID? = nil, in context: NSManagedObjectContext) throws {
        guard !isNameInUse(name, among: try libraryState(in: context).timelines, excluding: id) else {
            throw TimelineNameError.duplicate
        }
    }

    nonisolated private static func nameKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }

    private static func ensureLibraryAllowsChanges() throws {
        guard !PhotoStorageModeStore.shared.mode.isMigrating else {
            throw PhotoStorageMigrationError.attention("Let the photo storage switch finish before changing timelines.")
        }
    }
}

private extension String {
    nonisolated var nilIfEmpty: String? { isEmpty ? nil : self }
}
