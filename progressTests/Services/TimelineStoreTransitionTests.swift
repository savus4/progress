import CoreData
import Foundation
import Observation
import Testing
@testable import progress

@MainActor
struct TimelineStoreTransitionTests {
    @Test("Timelines can be renamed and created after reopening or replacing their store",
          .timeLimit(.minutes(1)), arguments: [false, true])
    func renameAfterStoreTransition(replacesStore: Bool) async throws {
        let library = try await PhotoStorageScenarioLibrary(empty: true)
        defer { library.cleanup() }
        let persistence = library.persistence
        let context = persistence.container.viewContext
        let id = try await TimelineStore.create(name: "Alex", in: context)
        try await TimelineStore.rename(id: TimelineIdentity.defaultID, to: "Me", in: context)
        let selection = TimelineSelectionStore(defaults: library.defaults)
        selection.select(id)
        await selection.start(in: context)
        try #require(selection.selectedName == "Alex")
        let originalStore = try #require(persistence.container.persistentStoreCoordinator.persistentStores.first)
        let filename = replacesStore ? try await persistence.copyLibraryForLocalStorage() : nil

        try await persistence.reloadCloudConfiguration(cloudEnabled: false, storeFilename: filename)

        #expect(persistence.container.viewContext === context)
        #expect(persistence.container.persistentStoreCoordinator.persistentStores.first !== originalStore)
        // Keep the observer alive, with no intervening start call as in the crash.
        try await selection.rename(id: id, to: "Alexandra", in: context)
        try await selection.rename(id: TimelineIdentity.defaultID, to: "Myself", in: context)
        let newID = try await selection.create(name: "Sam", in: context)

        #expect(selection.errorMessage == nil)
        #expect(selection.selectedID == newID)
        #expect(selection.selectedName == "Sam")
        #expect(selection.timelines.count == 3)
        #expect(selection.timelines.first { $0.id == id }?.name == "Alexandra")
        #expect(selection.timelines.first { $0.id == TimelineIdentity.defaultID }?.name == "Myself")
        #expect(try await TimelineStore.snapshots(in: context) == selection.timelines)
    }

    @Test("Attaching a replacement store refreshes timeline metadata without restarting its observer",
          .timeLimit(.minutes(1)))
    func replacementStoreRefreshesSelection() async throws {
        let library = try await PhotoStorageScenarioLibrary(empty: true)
        defer { library.cleanup() }
        let persistence = library.persistence
        let context = persistence.container.viewContext
        let id = try await TimelineStore.create(name: "Copied timeline", in: context)
        let selection = TimelineSelectionStore(defaults: library.defaults)
        selection.select(id)
        await selection.start(in: context)
        let filename = try await persistence.copyLibraryForLocalStorage()
        try await selection.rename(id: id, to: "Source timeline", in: context)
        _ = try await selection.create(name: "Source only", in: context)
        selection.select(id)
        try #require(selection.selectedName == "Source timeline")
        try #require(selection.timelines.count == 3)

        try await persistence.reloadCloudConfiguration(cloudEnabled: false, storeFilename: filename)
        await waitForTimelines(in: selection, names: [
            TimelineIdentity.defaultID: TimelineIdentity.defaultName,
            id: "Copied timeline"
        ])

        #expect(selection.selectedID == id)
        #expect(selection.selectedName == "Copied timeline")
        #expect(selection.errorMessage == nil)
        // A save through another caller must still refresh the retained observer.
        try await TimelineStore.rename(id: id, to: "Renamed replacement", in: context)
        await waitForTimelines(in: selection, names: [
            TimelineIdentity.defaultID: TimelineIdentity.defaultName,
            id: "Renamed replacement"
        ])
        #expect(selection.selectedName == "Renamed replacement")
        #expect(selection.errorMessage == nil)
    }

    private func waitForTimelines(in selection: TimelineSelectionStore, names: [UUID: String]) async {
        let (changes, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        var iterator = changes.makeAsyncIterator()
        while true {
            withObservationTracking {
                _ = selection.timelines
            } onChange: {
                continuation.yield(())
            }
            if selection.timelines.count == names.count,
               selection.timelines.allSatisfy({ names[$0.id] == $0.name }) {
                return
            }
            guard await iterator.next() != nil else { return }
        }
    }
}
