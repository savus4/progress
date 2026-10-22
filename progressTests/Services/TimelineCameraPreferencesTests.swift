import CoreData
import Foundation
import Testing
@testable import progress

@MainActor
struct TimelineCameraPreferencesTests {
    @Test("Live Photo choices belong to each timeline and survive switching and restart", arguments: [false, true])
    func preferencesAreIndependent(localMode: Bool) async throws {
        let library = try await PhotoStorageScenarioLibrary(empty: true)
        defer { library.cleanup() }
        if localMode { try library.modeStore.set(.local) }
        let context = library.persistence.container.viewContext
        let selection = TimelineSelectionStore(defaults: library.defaults)
        await selection.start(in: context)
        let person = try await selection.create(name: "Alex", in: context)
        #expect(TimelineCameraPreferences.livePhotosEnabled(for: person, in: selection, legacyDefaults: library.defaults))
        try await TimelineCameraPreferences.setLivePhotosEnabled(false, for: person, supported: true,
                                                                 timelines: selection, context: context)
        selection.select(TimelineIdentity.defaultID)
        #expect(TimelineCameraPreferences.livePhotosEnabled(for: TimelineIdentity.defaultID, in: selection, legacyDefaults: library.defaults))
        selection.select(person)
        #expect(!TimelineCameraPreferences.livePhotosEnabled(for: person, in: selection, legacyDefaults: library.defaults))
        try await library.reopen()
        let restored = TimelineSelectionStore(defaults: library.defaults)
        await restored.start(in: library.persistence.container.viewContext)
        #expect(restored.selectedID == person)
        #expect(!TimelineCameraPreferences.livePhotosEnabled(for: person, in: restored, legacyDefaults: library.defaults))
        #expect(TimelineCameraPreferences.livePhotosEnabled(for: TimelineIdentity.defaultID, in: restored, legacyDefaults: library.defaults))
    }

    @Test("Unsupported cameras neither migrate nor change synced preferences", arguments: [nil, true, false] as [Bool?])
    func unsupportedCameraDoesNotWrite(existingChoice: Bool?) async throws {
        let library = try await PhotoStorageScenarioLibrary(empty: true)
        defer { library.cleanup() }
        let context = library.persistence.container.viewContext
        library.defaults.set(false, forKey: CameraPreferenceKey.livePhotoCaptureEnabled)
        let selection = TimelineSelectionStore(defaults: library.defaults)
        await selection.start(in: context)
        if let existingChoice {
            try await selection.setLivePhotoCaptureEnabled(existingChoice, for: TimelineIdentity.defaultID, in: context)
        }
        let before = try await TimelineStore.snapshots(in: context)
        let countBefore = try context.count(for: Timeline.fetchRequest())
        let preferred = TimelineCameraPreferences.livePhotosEnabled(for: TimelineIdentity.defaultID, in: selection,
                                                                    legacyDefaults: library.defaults)
        #expect(!TimelineCameraPreferences.capturesLivePhoto(preferred: preferred, supported: false))
        try await TimelineCameraPreferences.migrateLegacyPreference(for: TimelineIdentity.defaultID, supported: false,
            timelines: selection, context: context, legacyDefaults: library.defaults)
        try await TimelineCameraPreferences.setLivePhotosEnabled(!preferred, for: TimelineIdentity.defaultID, supported: false,
                                                                 timelines: selection, context: context)
        #expect(try await TimelineStore.snapshots(in: context) == before)
        #expect(try context.count(for: Timeline.fetchRequest()) == countBefore)
        #expect(!context.hasChanges)
        #expect(TimelineCameraPreferences.livePhotosEnabled(for: TimelineIdentity.defaultID, in: selection,
                                                           legacyDefaults: library.defaults) == preferred)
    }

    @Test("Default inherits its legacy choice once; new timelines do not, and explicit synced choices win",
          arguments: [false, true])
    func legacyMigrationPreservesExplicitChoices(legacyEnabled: Bool) async throws {
        let library = try await PhotoStorageScenarioLibrary(empty: true)
        defer { library.cleanup() }
        let context = library.persistence.container.viewContext
        let selection = TimelineSelectionStore(defaults: library.defaults)
        await selection.start(in: context)
        library.defaults.set(legacyEnabled, forKey: CameraPreferenceKey.livePhotoCaptureEnabled)
        let other = try await selection.create(name: "Alex", in: context)
        try await TimelineCameraPreferences.migrateLegacyPreference(for: other, supported: true, timelines: selection,
            context: context, legacyDefaults: library.defaults)
        #expect(selection.timelines.first { $0.id == other }?.livePhotoPreference == nil)
        #expect(TimelineCameraPreferences.livePhotosEnabled(for: other, in: selection, legacyDefaults: library.defaults))
        try await TimelineCameraPreferences.migrateLegacyPreference(for: TimelineIdentity.defaultID, supported: true,
            timelines: selection, context: context, legacyDefaults: library.defaults)
        #expect(selection.timelines.first { $0.id == TimelineIdentity.defaultID }?.livePhotoPreference?.isEnabled == legacyEnabled)
        try await selection.setLivePhotoCaptureEnabled(!legacyEnabled, for: TimelineIdentity.defaultID, in: context)
        let explicit = selection.timelines.first { $0.id == TimelineIdentity.defaultID }?.livePhotoPreference
        try await TimelineCameraPreferences.migrateLegacyPreference(for: TimelineIdentity.defaultID, supported: true,
            timelines: selection, context: context, legacyDefaults: library.defaults)
        #expect(selection.timelines.first { $0.id == TimelineIdentity.defaultID }?.livePhotoPreference == explicit)
    }

    @Test("A newer rename and a newer Live Photo choice merge independently in either direction", arguments: [false, true])
    func independentMetadataClocks(preferenceInSource: Bool) async throws {
        let first = try await PhotoStorageScenarioLibrary(empty: true)
        let second = try await PhotoStorageScenarioLibrary(empty: true)
        defer { first.cleanup(); second.cleanup() }
        let source = first.persistence.container.viewContext
        let target = second.persistence.container.viewContext
        let id = UUID()
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        let newDate = oldDate.addingTimeInterval(100)
        for (context, isSource) in [(source, true), (target, false)] {
            let row = Timeline(context: context)
            row.id = id
            row.name = isSource ? "New name" : "Old name"
            row.modifiedAt = isSource ? newDate : oldDate
            row.livePhotoCaptureEnabled = NSNumber(value: isSource != preferenceInSource)
            row.livePhotoPreferenceModifiedAt = isSource == preferenceInSource ? newDate : oldDate
            try context.save()
        }
        try await TimelineLibraryCopy.merge(from: source, to: target)
        let merged = try #require(try await TimelineStore.snapshots(in: target).first { $0.id == id })
        #expect(merged.name == "New name")
        #expect(merged.livePhotoPreference?.isEnabled == false)
        #expect(merged.livePhotoPreference?.modifiedAt == newDate)
        try await TimelineLibraryCopy.merge(from: target, to: source)
        let returned = try #require(try await TimelineStore.snapshots(in: source).first { $0.id == id })
        #expect(returned == merged)
        let selection = TimelineSelectionStore(defaults: first.defaults)
        await selection.start(in: source)
        try await selection.rename(id: id, to: "Renamed again", in: source)
        #expect(selection.timelines.first { $0.id == id }?.livePhotoPreference == merged.livePhotoPreference)
    }

    @Test("Duplicate cloud metadata resolves preferences by their own date, with a deterministic tie")
    func duplicateMetadataKeepsLatestPreference() async throws {
        let library = try await PhotoStorageScenarioLibrary(empty: true)
        defer { library.cleanup() }
        let context = library.persistence.container.viewContext
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        for enabled in [true, false] {
            let row = Timeline(context: context)
            row.id = id; row.name = "Alex"
            row.modifiedAt = enabled ? date.addingTimeInterval(100) : date
            row.livePhotoCaptureEnabled = NSNumber(value: enabled)
            row.livePhotoPreferenceModifiedAt = date
        }
        try context.save()
        #expect(try await TimelineStore.snapshots(in: context).first { $0.id == id }?.livePhotoPreference?.isEnabled == false)
        try await TimelineStore.markDeleted(id: id, in: context)
        await #expect(throws: TimelineOperationError.self) {
            try await TimelineStore.setLivePhotoCaptureEnabled(true, for: id, in: context)
        }
        #expect(try context.fetch(Timeline.fetchRequest()).allSatisfy { $0.livePhotoPreference == nil })
    }
}
