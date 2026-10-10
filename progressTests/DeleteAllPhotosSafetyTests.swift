import CoreData
import Foundation
import Testing
@testable import progress

@MainActor
@Suite("Delete All Safety")
struct DeleteAllPhotosSafetyTests {
    @Test("Incomplete cloud deletion keeps tombstones and never rebuilds the store", arguments: [ExportOutcome.timedOut, .failed])
    func incompleteDeletionPreservesHistory(outcome: ExportOutcome) async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        try fixture.insertPhoto(id: UUID(), assetName: "deleted-original.heic")

        let result = try await DeleteAllPhotosMaintenance.perform(
            deletePhotos: {
                try await PhotoStorageService.shared.deleteAllPhotos(
                    context: fixture.context,
                    operations: operations(outcome: outcome)
                )
            },
            purgeOrphanedAssets: { _ in }
        )

        #expect(result.deletedCount == 1)
        #expect(!result.shouldRebuildPersistentStore)
        #expect(!result.isCloudDeletionComplete)
        #expect(try fixture.hasDeletionHistory())
    }

    @Test("An unrelated successful export cannot confirm this deletion")
    func unrelatedExportDoesNotConfirmDeletion() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        try fixture.insertPhoto(id: UUID(), assetName: "deleted-original.heic")

        let result = try await PhotoStorageService.shared.deleteAllPhotos(
            context: fixture.context,
            operations: operations(outcome: .completed)
        )

        #expect(!result.isCloudDeletionComplete)
        if case .confirmed = result.cloudMetadataDeletionState {
            Issue.record("An uncorrelated export event confirmed the photo deletion")
        }
        #expect(!result.shouldRebuildPersistentStore)
    }

    @Test("A photo created during upload draining is outside the deletion snapshot")
    func newPhotoSurvivesUploadDrain() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let originalID = UUID()
        let laterID = UUID()
        try fixture.insertPhoto(id: originalID, assetName: "deleted-original.heic")
        var insertionError: Error?
        var deletedAssetNames = Set<String>()

        let result = try await PhotoStorageService.shared.deleteAllPhotos(
            context: fixture.context,
            operations: operations(
                outcome: .timedOut,
                waitUntilUploadsIdle: {
                    do {
                        try fixture.insertPhoto(id: laterID, assetName: "later-original.heic")
                    } catch {
                        insertionError = error
                    }
                    await Task.yield()
                    return true
                },
                cleanup: { assetNames in
                    deletedAssetNames = assetNames
                    return []
                }
            )
        )
        if let insertionError { throw insertionError }

        #expect(result.deletedCount == 1)
        #expect(try fixture.photoIDs() == [laterID])
        #expect(deletedAssetNames == ["deleted-original.heic"])
        #expect(try fixture.hasDeletionHistory())
    }

    @Test("A photo created during remote cleanup survives the entire maintenance action")
    func newPhotoSurvivesMaintenance() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        let laterID = UUID()
        try fixture.insertPhoto(id: UUID(), assetName: "deleted-original.heic")
        var insertionError: Error?
        var purgeCount = 0
        let injectedOperations = operations(
            outcome: .timedOut,
            cleanup: { assetNames in
                #expect(assetNames == ["deleted-original.heic"])
                do {
                    #expect(try fixture.photoIDs().isEmpty)
                    try fixture.insertPhoto(id: laterID, assetName: "later-original.heic")
                } catch {
                    insertionError = error
                }
                await Task.yield()
                return []
            }
        )

        let result = try await DeleteAllPhotosMaintenance.perform(
            deletePhotos: {
                try await PhotoStorageService.shared.deleteAllPhotos(
                    context: fixture.context,
                    operations: injectedOperations
                )
            },
            purgeOrphanedAssets: { _ in purgeCount += 1 }
        )
        if let insertionError { throw insertionError }

        #expect(result.deletedCount == 1)
        #expect(purgeCount == 1)
        #expect(try fixture.photoIDs() == [laterID])
        #expect(try fixture.hasDeletionHistory())
    }

    @Test("An empty library does not request a persistent-store rebuild")
    func emptyLibraryKeepsStore() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }

        let result = try await PhotoStorageService.shared.deleteAllPhotos(
            context: fixture.context,
            operations: operations(outcome: .timedOut)
        )

        #expect(result.deletedCount == 0)
        #expect(!result.shouldRebuildPersistentStore)
    }

    @Test("Maintenance keeps newly staged capture bytes before its metadata is inserted")
    func stagedCaptureSurvivesMaintenance() async throws {
        let fixture = try StoreFixture()
        defer { fixture.close() }
        try fixture.insertPhoto(id: UUID(), assetName: "deleted-original.heic")
        let assetName = "new-capture.heic"
        let bytes = Data([0x10, 0x20, 0x30])
        var stagingError: Error?
        let injectedOperations = operations(
            outcome: .timedOut,
            cleanup: { _ in
                do {
                    _ = try fixture.cloud.stageAssetData(bytes, named: assetName)
                } catch {
                    stagingError = error
                }
                await Task.yield()
                return []
            }
        )
        let storage = PhotoStorageService(cloudKitService: fixture.cloud)

        _ = try await DeleteAllPhotosMaintenance.perform(
            deletePhotos: {
                try await storage.deleteAllPhotos(context: fixture.context, operations: injectedOperations)
            },
            purgeOrphanedAssets: { ignoreGracePeriod in
                await storage.purgeOrphanedAssets(context: fixture.context, ignoreGracePeriod: ignoreGracePeriod)
            }
        )
        if let stagingError { throw stagingError }

        let stagedURL = try #require(fixture.cloud.stagedAssetURL(named: assetName))
        #expect(try Data(contentsOf: stagedURL) == bytes)
    }

    enum ExportOutcome: Sendable {
        case completed
        case failed
        case timedOut

        var result: CloudSyncMonitor.ExportWaitResult {
            switch self {
            case .completed: .completed
            case .failed: .failed("Injected export failure")
            case .timedOut: .timedOut
            }
        }
    }

    private func operations(
        outcome: ExportOutcome,
        waitUntilUploadsIdle: @escaping @MainActor () async -> Bool = { true },
        cleanup: @escaping @MainActor (Set<String>) async -> Set<String> = { _ in [] }
    ) -> DeleteAllPhotosOperations {
        DeleteAllPhotosOperations(
            cancelPendingUploads: {},
            waitUntilUploadsIdle: waitUntilUploadsIdle,
            isLocalModeActive: { false },
            waitForNextExportCompletion: { outcome.result },
            deleteAssets: { _ in },
            deleteAssetsAndWaitForRemoteCleanup: cleanup
        )
    }

    /// A real, isolated SQLite store makes tombstone loss observable without CloudKit.
    private final class StoreFixture {
        let container: NSPersistentContainer
        let directoryURL: URL
        let cloud: CloudKitService
        private let storeURL: URL
        private let options: [AnyHashable: Any] = [NSPersistentHistoryTrackingKey: true]

        var context: NSManagedObjectContext { container.viewContext }

        init() throws {
            let model = PersistenceController(inMemory: true).container.managedObjectModel
            container = NSPersistentContainer(name: "DeleteAllSafety", managedObjectModel: model)
            directoryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("DeleteAllSafety-\(UUID())", isDirectory: true)
            storeURL = directoryURL.appendingPathComponent("photos.sqlite")
            cloud = CloudKitService(
                stagingDirectoryURL: directoryURL.appendingPathComponent("staging", isDirectory: true),
                temporaryReadableAssetsDirectoryURL: directoryURL.appendingPathComponent("readable", isDirectory: true)
            )
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try addStore()
        }

        func insertPhoto(id: UUID, assetName: String) throws {
            let entity = try #require(container.managedObjectModel.entitiesByName["DailyPhoto"])
            let photo = DailyPhoto(entity: entity, insertInto: context)
            photo.id = id
            photo.captureDate = Date(timeIntervalSince1970: 1_000)
            photo.fullImageAssetName = assetName
            try context.save()
        }

        func photoIDs() throws -> Set<UUID> {
            Set(try context.fetch(DailyPhoto.fetchRequest()).compactMap(\.id))
        }

        func hasDeletionHistory() throws -> Bool {
            let request = NSPersistentHistoryChangeRequest.fetchHistory(after: Date.distantPast)
            request.resultType = .transactionsAndChanges
            let result = try #require(context.execute(request) as? NSPersistentHistoryResult)
            let transactions = result.result as? [NSPersistentHistoryTransaction] ?? []
            return transactions.flatMap { $0.changes ?? [] }.contains { $0.changeType == .delete }
        }

        func close() {
            context.reset()
            let coordinator = container.persistentStoreCoordinator
            for store in coordinator.persistentStores {
                try? coordinator.remove(store)
            }
            try? FileManager.default.removeItem(at: directoryURL)
        }

        private func addStore() throws {
            _ = try container.persistentStoreCoordinator.addPersistentStore(
                ofType: NSSQLiteStoreType,
                configurationName: nil,
                at: storeURL,
                options: options
            )
        }
    }
}
