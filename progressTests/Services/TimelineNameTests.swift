import CoreData
import Foundation
import Testing
@testable import progress

@MainActor
struct TimelineNameTests {
    @Test("Creation rejects names differing only by case, width or surrounding whitespace",
          arguments: ["Alex", " alex \n", "ALEX", "Ａｌｅｘ"])
    func duplicateCreationDoesNotSave(name: String) async throws {
        let persistence = PersistenceController(inMemory: true)
        try await PhotoStorageScenarioLibrary.waitUntilLoaded(persistence)
        let context = persistence.container.viewContext
        _ = try await TimelineStore.create(name: "Alex", in: context)

        await #expect(throws: TimelineNameError.duplicate) {
            _ = try await TimelineStore.create(name: name, in: context)
        }
        #expect(try context.count(for: Timeline.fetchRequest()) == 1)
        #expect(context.hasChanges == false)
    }

    @Test("Renaming cannot take another timeline's name and leaves metadata unchanged")
    func duplicateRenameDoesNotSave() async throws {
        let persistence = PersistenceController(inMemory: true)
        try await PhotoStorageScenarioLibrary.waitUntilLoaded(persistence)
        let context = persistence.container.viewContext
        _ = try await TimelineStore.create(name: "Alex", in: context)
        let other = try await TimelineStore.create(name: "Sam", in: context)
        let before = try await TimelineStore.snapshots(in: context)

        await #expect(throws: TimelineNameError.duplicate) {
            try await TimelineStore.rename(id: other, to: " aLeX ", in: context)
        }
        #expect(try await TimelineStore.snapshots(in: context) == before)
        #expect(context.hasChanges == false)
    }

    @Test("The virtual Default reserves its name until renamed")
    func virtualDefaultReservesName() async throws {
        let persistence = PersistenceController(inMemory: true)
        try await PhotoStorageScenarioLibrary.waitUntilLoaded(persistence)
        let context = persistence.container.viewContext
        await #expect(throws: TimelineNameError.duplicate) {
            _ = try await TimelineStore.create(name: " default ", in: context)
        }
        try await TimelineStore.rename(id: TimelineIdentity.defaultID, to: "Me", in: context)
        let id = try await TimelineStore.create(name: "Default", in: context)
        #expect(id != TimelineIdentity.defaultID)
        #expect(try await TimelineStore.snapshots(in: context).map(\.name) == ["Me", "Default"])
    }

    @Test("A timeline may change its own capitalization; canonically equivalent names still conflict")
    func ownNameAndUnicodeEquivalence() async throws {
        let persistence = PersistenceController(inMemory: true)
        try await PhotoStorageScenarioLibrary.waitUntilLoaded(persistence)
        let context = persistence.container.viewContext
        let id = try await TimelineStore.create(name: "José", in: context)
        try await TimelineStore.rename(id: id, to: "JOSÉ", in: context)
        await #expect(throws: TimelineNameError.duplicate) {
            _ = try await TimelineStore.create(name: "Jose\u{301}", in: context)
        }
        #expect(try await TimelineStore.snapshots(in: context).first { $0.id == id }?.name == "JOSÉ")
    }

    @Test("A deleted timeline's name can be reused without reusing its ownership")
    func deletedNameCanBeReused() async throws {
        let persistence = PersistenceController(inMemory: true)
        try await PhotoStorageScenarioLibrary.waitUntilLoaded(persistence)
        let context = persistence.container.viewContext
        let old = try await TimelineStore.create(name: "Alex", in: context)
        try await TimelineStore.markDeleted(id: old, in: context)
        let replacement = try await TimelineStore.create(name: "alex", in: context)
        #expect(replacement != old)
        #expect(try await TimelineStore.state(in: context).deletedIDs.contains(old))
    }

    @Test("Offline name collisions resolve consistently, preserving ownership and existing suffixes")
    func offlineCollisionsConverge() async throws {
        let forward = try await resolveOfflineFixture(reversed: false)
        let reverse = try await resolveOfflineFixture(reversed: true)
        #expect(forward == reverse)
        #expect(Set(forward.values) == ["Default", "Alex", "alex (3)", "Alex (2)"])
    }

    @Test("A synced collision with Default or a maximum-length name stays within the name limit",
          arguments: ["Default", String(repeating: "a", count: 80)])
    func syncedNamesStayValid(name: String) async throws {
        let persistence = PersistenceController(inMemory: true)
        try await PhotoStorageScenarioLibrary.waitUntilLoaded(persistence)
        let context = persistence.container.viewContext
        if name != "Default" { _ = try await TimelineStore.create(name: name, in: context) }
        let incoming = Timeline(context: context)
        incoming.id = UUID()
        incoming.name = name
        incoming.createdAt = .distantFuture
        incoming.modifiedAt = incoming.createdAt
        try context.save()
        try await TimelineStore.resolveNameConflicts(in: context)
        let names = try await TimelineStore.snapshots(in: context).map(\.name)
        #expect(names.contains(name))
        #expect(names.contains(String(name.prefix(76)) + " (2)"))
        #expect(names.allSatisfy { $0.count <= TimelineStore.maxNameLength })
        #expect(Set(names).count == names.count)
    }

    private func resolveOfflineFixture(reversed: Bool) async throws -> [UUID: String] {
        let persistence = PersistenceController(inMemory: true)
        try await PhotoStorageScenarioLibrary.waitUntilLoaded(persistence)
        let context = persistence.container.viewContext
        let entries = [
            (UUID(uuidString: "10000000-0000-0000-0000-000000000001")!, "Alex"),
            (UUID(uuidString: "20000000-0000-0000-0000-000000000001")!, "alex"),
            (UUID(uuidString: "30000000-0000-0000-0000-000000000001")!, "Alex (2)")
        ]
        for (id, name) in reversed ? Array(entries.reversed()) : entries {
            let timeline = Timeline(context: context)
            timeline.id = id
            timeline.name = name
            timeline.createdAt = Date(timeIntervalSince1970: 1)
            timeline.modifiedAt = timeline.createdAt
            let photo = DailyPhoto(context: context)
            photo.id = UUID()
            photo.timelineID = id
        }
        try context.save()
        let domain = "TimelineNameConflict-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let selection = TimelineSelectionStore(defaults: defaults)
        await selection.start(in: context)
        let first = try await TimelineStore.snapshots(in: context)
        try await TimelineStore.resolveNameConflicts(in: context)
        #expect(try await TimelineStore.snapshots(in: context) == first)
        #expect(context.hasChanges == false)
        #expect(Set(try context.fetch(DailyPhoto.fetchRequest()).compactMap(\.timelineID)) == Set(entries.map(\.0)))
        #expect(try context.count(for: Timeline.fetchRequest()) == 3)
        return Dictionary(uniqueKeysWithValues: first.map { ($0.id, $0.name) })
    }
}
