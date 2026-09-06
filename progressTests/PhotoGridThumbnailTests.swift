import CoreData
import Foundation
import Testing
import UIKit
@testable import progress

@MainActor
struct PhotoGridThumbnailTests {
    @Test("Canceling a queued thumbnail removes its decode and permits a later retry")
    func canceledDecodeCanBeRetried() async throws {
        let persistence = PersistenceController(inMemory: true)
        let photo = DailyPhoto(context: persistence.container.viewContext)
        try persistence.container.viewContext.obtainPermanentIDs(for: [photo])
        let (events, continuation) = AsyncStream<Void>.makeStream()
        let queue = ObservedThumbnailQueue { continuation.yield(()) }
        queue.isSuspended = true
        defer { queue.isSuspended = false; continuation.finish() }
        let cache = DecodedThumbnailCache(workerQueue: queue)
        let data = try makeJPEG()
        let objectID = photo.objectID
        let task = Task { await cache.image(for: objectID, data: data, priority: .low) }
        var iterator = events.makeAsyncIterator()
        await iterator.next()
        let operation = try #require(queue.operations.first)

        task.cancel()
        #expect(await task.value == nil)
        #expect(operation.isCancelled)
        #expect(cache.cachedImage(for: objectID) == nil)

        queue.isSuspended = false
        let image = try #require(await cache.image(for: objectID, data: data))
        #expect(cache.cachedImage(for: objectID) === image)
    }

    @Test("Visible thumbnails promote the existing queued decode without duplicating it")
    func promotesPrefetchInPlace() async throws {
        let persistence = PersistenceController(inMemory: true)
        let photo = DailyPhoto(context: persistence.container.viewContext)
        try persistence.container.viewContext.obtainPermanentIDs(for: [photo])
        let (events, continuation) = AsyncStream<Void>.makeStream()
        let queue = ObservedThumbnailQueue { continuation.yield(()) }
        queue.isSuspended = true
        defer { queue.isSuspended = false; continuation.finish() }
        let cache = DecodedThumbnailCache(workerQueue: queue)
        let data = try makeJPEG()
        let objectID = photo.objectID
        let task = Task { await cache.image(for: objectID, data: data, priority: .low) }
        var iterator = events.makeAsyncIterator()
        await iterator.next()
        let operation = try #require(queue.operations.first)

        cache.setPriority(.veryHigh, for: objectID)
        #expect(queue.operationCount == 1)
        #expect(operation.queuePriority == .veryHigh)
        queue.isSuspended = false
        #expect(await task.value != nil)
    }

    @Test("Cache purge cancels outstanding decodes and resumes their callers")
    func purgeResumesPendingDecode() async throws {
        let persistence = PersistenceController(inMemory: true)
        let photo = DailyPhoto(context: persistence.container.viewContext)
        try persistence.container.viewContext.obtainPermanentIDs(for: [photo])
        let (events, continuation) = AsyncStream<Void>.makeStream()
        let queue = ObservedThumbnailQueue { continuation.yield(()) }
        queue.isSuspended = true
        defer { queue.isSuspended = false; continuation.finish() }
        let cache = DecodedThumbnailCache(workerQueue: queue)
        let data = try makeJPEG()
        let objectID = photo.objectID
        let task = Task { await cache.image(for: objectID, data: data) }
        var iterator = events.makeAsyncIterator()
        await iterator.next()

        cache.removeAllImages()
        #expect(await task.value == nil)
        #expect(cache.cachedImage(for: objectID) == nil)
    }

    @Test("Stored legacy thumbnails load by object ID in batches without original assets")
    func loadsExistingThumbnailBlobs() async throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let legacyJPEG = try makeJPEG()
        let first = DailyPhoto(context: context)
        first.thumbnailData = legacyJPEG
        let second = DailyPhoto(context: context)
        second.thumbnailData = legacyJPEG
        let missing = DailyPhoto(context: context)
        try context.save()
        let provider = PhotoThumbnailDataProvider(context: persistence.makeBackgroundContext())
        let ids = [first.objectID, second.objectID, missing.objectID]

        #expect(await provider.thumbnailData(for: first.objectID, nearbyObjectIDs: ids) == legacyJPEG)
        #expect(await provider.thumbnailData(for: second.objectID) == legacyJPEG)
        #expect(await provider.thumbnailData(for: missing.objectID) == nil)
        provider.purge()
        #expect(await provider.thumbnailData(for: second.objectID) == legacyJPEG)
        #expect(first.fullImageData == nil)
        #expect(second.fullImageAssetName == nil)
    }

    @Test("Expanded previews upgrade stored thumbnails and are reused when zooming back out")
    func expandedThumbnailReusesLargestCachedImage() async throws {
        let persistence = PersistenceController(inMemory: true)
        let photo = DailyPhoto(context: persistence.container.viewContext)
        try persistence.container.viewContext.obtainPermanentIDs(for: [photo])
        let cache = DecodedThumbnailCache()
        let data = try makeJPEG()
        let small = try #require(await cache.image(for: photo.objectID, data: data))
        #expect(cache.cachedImage(for: photo.objectID, resolution: .expanded) == nil)

        let large = try #require(await cache.image(for: photo.objectID, data: data, resolution: .expanded))
        #expect(large.size.height > small.size.height)
        #expect(cache.cachedImage(for: photo.objectID) === large)
        #expect(await cache.image(for: photo.objectID, data: nil) === large)

        cache.removeImage(for: photo.objectID)
        #expect(cache.cachedImage(for: photo.objectID) == nil)
        #expect(cache.cachedImage(for: photo.objectID, resolution: .expanded) == nil)
    }

    private func makeJPEG() throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 600)).image { context in
            UIColor.purple.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 600))
        }
        return try #require(image.jpegData(compressionQuality: 0.7))
    }
}

nonisolated private final class ObservedThumbnailQueue: OperationQueue, @unchecked Sendable {
    private let didEnqueue: @Sendable () -> Void

    init(didEnqueue: @escaping @Sendable () -> Void) {
        self.didEnqueue = didEnqueue
        super.init()
    }

    override func addOperation(_ operation: Operation) {
        super.addOperation(operation)
        didEnqueue()
    }
}
