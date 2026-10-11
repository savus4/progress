import CoreData
import Foundation
import Testing
@testable import progress

@MainActor
struct PhotoDetailLibrarySaveStateTests {
    @Test("A save completing after paging records the saved photo and leaves the new photo unsaved")
    func completionAfterPagingBelongsToSavedPhoto() async throws {
        let persistence = PersistenceController(inMemory: true)
        let items = try makeItems(context: persistence.container.viewContext)
        let (started, startedContinuation) = AsyncStream<PhotoLibrarySaveItem>.makeStream()
        let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
        defer {
            startedContinuation.finish()
            releaseContinuation.finish()
        }
        let state = PhotoDetailLibrarySaveState(initialObjectID: items[0].objectID) { item in
            startedContinuation.yield(item)
            var iterator = release.makeAsyncIterator()
            await iterator.next()
        }
        let save = Task { try await state.save(items[0]) }
        var startedIterator = started.makeAsyncIterator()
        let savedItem = try #require(await startedIterator.next())
        #expect(savedItem.fullImageAssetName == items[0].fullImageAssetName)

        state.selectPhoto(items[1].objectID)
        #expect(!state.hasSavedCurrentPhoto)
        releaseContinuation.yield(())
        try await save.value

        #expect(!state.hasSavedCurrentPhoto)
        state.selectPhoto(items[0].objectID)
        #expect(state.hasSavedCurrentPhoto)
    }

    @Test("Failed saves leave the photo eligible for a successful retry")
    func failureDoesNotMarkPhotoSaved() async throws {
        let persistence = PersistenceController(inMemory: true)
        let items = try makeItems(context: persistence.container.viewContext)
        var attempts = 0
        let state = PhotoDetailLibrarySaveState(initialObjectID: items[0].objectID) { _ in
            attempts += 1
            if attempts == 1 {
                throw CocoaError(.fileWriteOutOfSpace)
            }
        }

        await #expect(throws: CocoaError.self) {
            try await state.save(items[0])
        }
        #expect(!state.hasSavedCurrentPhoto)
        try await state.save(items[0])
        #expect(state.hasSavedCurrentPhoto)
        #expect(attempts == 2)
    }

    @Test("Successful saves remain attached to each photo across selection and deletion selection changes")
    func selectionPreservesEachSavedPhoto() async throws {
        let persistence = PersistenceController(inMemory: true)
        let items = try makeItems(context: persistence.container.viewContext)
        var savedNames: [String?] = []
        let state = PhotoDetailLibrarySaveState(initialObjectID: items[0].objectID) { item in
            savedNames.append(item.fullImageAssetName)
        }

        try await state.save(items[0])
        #expect(state.hasSavedCurrentPhoto)
        state.selectPhoto(items[1].objectID)
        #expect(!state.hasSavedCurrentPhoto)
        try await state.save(items[1])
        #expect(state.hasSavedCurrentPhoto)

        // A deletion transition can change the current object without changing its index.
        state.selectPhoto(items[0].objectID)
        #expect(state.hasSavedCurrentPhoto)
        state.selectPhoto(nil)
        #expect(!state.hasSavedCurrentPhoto)
        #expect(savedNames == items.map(\.fullImageAssetName))
    }

    private func makeItems(context: NSManagedObjectContext) throws -> [PhotoDetailItem] {
        let photos = (0..<2).map { index in
            let photo = DailyPhoto(context: context)
            photo.id = UUID()
            photo.fullImageAssetName = "photo-\(index).heic"
            return photo
        }
        try context.obtainPermanentIDs(for: photos)
        return photos.map(PhotoDetailItem.init(photo:))
    }
}
