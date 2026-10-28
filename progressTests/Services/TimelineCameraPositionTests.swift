import CoreData
import Foundation
import Testing
@testable import progress

@MainActor
struct TimelineCameraPositionTests {
    @Test("Front is the default; camera choices survive timeline switching and reopening", arguments: [false, true])
    func cameraChoicePersists(localMode: Bool) async throws {
        let library = try await PhotoStorageScenarioLibrary(empty: true)
        defer { library.cleanup() }
        if localMode { try library.modeStore.set(.local) }
        let selection = TimelineSelectionStore(defaults: library.defaults)
        let context = library.persistence.container.viewContext
        await selection.start(in: context)
        let other = try await selection.create(name: "Garden", in: context)
        #expect(TimelineCameraPreferences.cameraPosition(for: other, in: selection) == .front)
        #expect(TimelineCameraPreferences.cameraPosition(for: TimelineIdentity.defaultID, in: selection) == .front)

        try await selection.setCameraPosition(.back, for: other, in: context)
        selection.select(TimelineIdentity.defaultID)
        #expect(TimelineCameraPreferences.cameraPosition(for: selection.selectedID, in: selection) == .front)
        selection.select(other)
        #expect(TimelineCameraPreferences.cameraPosition(for: selection.selectedID, in: selection) == .back)
        try await library.reopen()
        let restored = TimelineSelectionStore(defaults: library.defaults)
        await restored.start(in: library.persistence.container.viewContext)
        #expect(restored.selectedID == other)
        #expect(TimelineCameraPreferences.cameraPosition(for: other, in: restored) == .back)
        #expect(TimelineCameraPreferences.cameraPosition(for: TimelineIdentity.defaultID, in: restored) == .front)
        try await restored.setCameraPosition(.front, for: other, in: library.persistence.container.viewContext)
        #expect(TimelineCameraPreferences.cameraPosition(for: other, in: restored) == .front)
    }

    @Test("Camera selection, Live Photos, and names merge on independent clocks", arguments: [false, true])
    func cameraChoiceMergesIndependently(cameraChoiceInSource: Bool) async throws {
        let first = try await PhotoStorageScenarioLibrary(empty: true)
        let second = try await PhotoStorageScenarioLibrary(empty: true)
        defer { first.cleanup(); second.cleanup() }
        let source = first.persistence.container.viewContext
        let target = second.persistence.container.viewContext
        let id = UUID()
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = older.addingTimeInterval(100)
        for (context, isSource) in [(source, true), (target, false)] {
            let row = Timeline(context: context)
            row.id = id
            row.name = isSource ? "New name" : "Old name"
            row.modifiedAt = isSource ? newer : older
            row.livePhotoCaptureEnabled = NSNumber(value: isSource)
            row.livePhotoPreferenceModifiedAt = isSource ? older : newer
            row.cameraPositionRaw = isSource == cameraChoiceInSource ? "back" : "front"
            row.cameraPreferenceModifiedAt = isSource == cameraChoiceInSource ? newer : older
            try context.save()
        }
        try await TimelineLibraryCopy.merge(from: source, to: target)
        let merged = try #require(try await TimelineStore.snapshots(in: target).first { $0.id == id })
        #expect(merged.name == "New name")
        #expect(merged.livePhotoPreference?.isEnabled == false)
        #expect(merged.cameraPreference == TimelineCameraPreference(position: .back, modifiedAt: newer))
        try await TimelineLibraryCopy.merge(from: target, to: source)
        #expect(try await TimelineStore.snapshots(in: source).first { $0.id == id } == merged)
        try await TimelineStore.rename(id: id, to: "Renamed again", in: source)
        try await TimelineStore.setLivePhotoCaptureEnabled(true, for: id, in: source)
        #expect(try await TimelineStore.snapshots(in: source).first { $0.id == id }?.cameraPreference == merged.cameraPreference)
    }

    @Test("Duplicate metadata resolves camera ties consistently and deletion clears camera choices")
    func duplicateChoicesAndDeletion() async throws {
        let library = try await PhotoStorageScenarioLibrary(empty: true)
        defer { library.cleanup() }
        let context = library.persistence.container.viewContext
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        for position in CameraPosition.allCases {
            let row = Timeline(context: context)
            row.id = id
            row.name = "Garden"
            row.cameraPositionRaw = position.rawValue
            row.cameraPreferenceModifiedAt = date
        }
        try context.save()
        let winner = try #require(try await TimelineStore.snapshots(in: context).first { $0.id == id }?.cameraPreference)
        #expect(winner.position == .front)
        try await TimelineStore.setCameraPosition(.back, for: id, in: context)
        #expect(try context.fetch(Timeline.fetchRequest()).allSatisfy { $0.cameraPreference?.position == .back })
        try await TimelineStore.markDeleted(id: id, in: context)
        await #expect(throws: TimelineOperationError.self) {
            try await TimelineStore.setCameraPosition(.front, for: id, in: context)
        }
        #expect(try context.fetch(Timeline.fetchRequest()).allSatisfy { $0.cameraPreference == nil })
        // A stale duplicate arriving after the tombstone must also be scrubbed.
        let stale = Timeline(context: context)
        stale.id = id
        stale.cameraPositionRaw = "back"
        stale.cameraPreferenceModifiedAt = date
        try context.save()
        try await TimelineStore.normalizeTombstones(in: context)
        #expect(try context.fetch(Timeline.fetchRequest()).allSatisfy {
            $0.cameraPositionRaw == nil && $0.cameraPreferenceModifiedAt == nil
        })
    }

    @Test("The virtual default can persist its own camera choice")
    func defaultTimelineChoice() async throws {
        let library = try await PhotoStorageScenarioLibrary(empty: true)
        defer { library.cleanup() }
        let context = library.persistence.container.viewContext
        let selection = TimelineSelectionStore(defaults: library.defaults)
        await selection.start(in: context)
        #expect(try context.count(for: Timeline.fetchRequest()) == 0)
        try await selection.setCameraPosition(.back, for: TimelineIdentity.defaultID, in: context)
        #expect(selection.timelines.first?.name == TimelineIdentity.defaultName)
        #expect(TimelineCameraPreferences.cameraPosition(for: TimelineIdentity.defaultID, in: selection) == .back)
        #expect(try context.count(for: Timeline.fetchRequest()) == 1)
    }
}
