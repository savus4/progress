import CoreData
import Foundation
import Observation
import Testing
import UserNotifications
@testable import progress

@MainActor
struct TimelineSelectionTests {
    @Test("An unnamed first timeline is Default, and creating another remembers its selection")
    func creatingAndRenamingPersistIdentity() async throws {
        let domain = "TimelineSelection-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let persistence = PersistenceController(inMemory: true)
        try await PhotoStorageScenarioLibrary.waitUntilLoaded(persistence)
        let context = persistence.container.viewContext
        let selection = TimelineSelectionStore(defaults: defaults)
        await selection.start(in: context)
        #expect(selection.isLoaded)
        #expect(selection.selectedName == "Default")
        #expect(selection.canRenameTimelines)
        #expect(selection.canDeleteTimeline(TimelineIdentity.defaultID) == false)
        #expect(try context.count(for: Timeline.fetchRequest()) == 0)

        let id = try await selection.create(name: "  Alex  ", in: context)
        #expect(selection.selectedID == id)
        #expect(selection.selectedName == "Alex")
        #expect(selection.canRenameTimelines)
        try await selection.rename(id: TimelineIdentity.defaultID, to: "Me", in: context)
        selection.select(TimelineIdentity.defaultID)
        #expect(selection.selectedName == "Me")
        try await selection.rename(id: id, to: "Alexandra", in: context)
        selection.select(id)

        let reopened = TimelineSelectionStore(defaults: defaults)
        await reopened.start(in: context)
        #expect(reopened.selectedID == id)
        #expect(reopened.selectedName == "Alexandra")
        #expect(reopened.timelines.count == 2)
        #expect(try context.count(for: Timeline.fetchRequest()) == 2)
    }

    @Test("Timeline names merged from another context update the switcher", .timeLimit(.minutes(1)))
    func importedNameUpdatesSelection() async throws {
        let domain = "TimelineNameSync-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let persistence = PersistenceController(inMemory: true)
        try await PhotoStorageScenarioLibrary.waitUntilLoaded(persistence)
        let context = persistence.container.viewContext
        let selection = TimelineSelectionStore(defaults: defaults)
        let id = try await selection.create(name: "Before", in: context)
        await selection.start(in: context)
        let (changes, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        withObservationTracking {
            _ = selection.timelines
        } onChange: {
            continuation.yield(())
        }
        try await TimelineStore.rename(id: id, to: "From another device", in: persistence.makeBackgroundContext())
        var iterator = changes.makeAsyncIterator()
        try #require(await iterator.next() != nil)
        #expect(selection.selectedName == "From another device")
        #expect(selection.selectedID == id)
    }

    @Test("A notification target remains selected while its metadata is still syncing")
    func pendingMetadataDoesNotRedirectCaptures() async throws {
        let domain = "TimelinePendingSync-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let persistence = PersistenceController(inMemory: true)
        try await PhotoStorageScenarioLibrary.waitUntilLoaded(persistence)
        let selection = TimelineSelectionStore(defaults: defaults)
        let id = UUID()
        selection.select(id)
        await selection.refresh(in: persistence.container.viewContext)
        #expect(selection.selectedID == id)
        #expect(selection.timelines.contains { $0.id == id })
        #expect(selection.selectedName == "Timeline")
        let reopened = TimelineSelectionStore(defaults: defaults)
        #expect(reopened.selectedID == id)
    }

    @Test("Invalid timeline names cannot create empty or excessive metadata", arguments: ["   ", String(repeating: "a", count: 81)])
    func invalidNamesDoNotSave(name: String) async throws {
        let persistence = PersistenceController(inMemory: true)
        try await PhotoStorageScenarioLibrary.waitUntilLoaded(persistence)
        let context = persistence.container.viewContext
        await #expect(throws: TimelineNameError.self) {
            _ = try await TimelineStore.create(name: name, in: context)
        }
        #expect(try context.count(for: Timeline.fetchRequest()) == 0)
    }

    @Test("Renaming a timeline updates scheduled notification names without moving its reminders")
    func reminderNamesFollowSyncedMetadata() async throws {
        let domain = "TimelineReminderNames-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let persistence = PersistenceController(inMemory: true)
        try await PhotoStorageScenarioLibrary.waitUntilLoaded(persistence)
        let context = persistence.container.viewContext
        let id = try await TimelineStore.create(name: "Alex", in: context)
        var requests: [UNNotificationRequest] = []
        let service = DailyReminderNotificationService(defaults: defaults, context: context) { requests = $0; return true }
        let times = [DailyReminderTime(hour: 9, minute: 0)]
        #expect(await service.updateReminderTimes(times, timelineID: id))
        #expect(requests.first?.content.title == "Time for Alex")
        let identifiers = requests.map(\.identifier)
        try await TimelineStore.rename(id: id, to: "Alexandra", in: context)
        #expect(await service.refreshReminders().value)
        #expect(requests.first?.content.title == "Time for Alexandra")
        #expect(requests.map(\.identifier) == identifiers)
        #expect(service.loadReminderTimes(timelineID: id) == times)
    }
}
