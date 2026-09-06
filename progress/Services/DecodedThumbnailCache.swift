import UIKit
import CoreData
import ImageIO

nonisolated final class DecodedThumbnailCache: @unchecked Sendable {
    static let shared = DecodedThumbnailCache()

    enum Resolution: Int, Sendable {
        case grid = 320
        case expanded = 640
    }

    private struct Key: Hashable {
        let objectID: NSManagedObjectID
        let resolution: Resolution
    }

    private final class CachedThumbnail {
        let image: UIImage
        let resolution: Resolution

        init(image: UIImage, resolution: Resolution) {
            self.image = image
            self.resolution = resolution
        }
    }

    // Object IDs are already stable cache keys; avoid URL/string allocation while scrolling.
    private let cache = NSCache<NSManagedObjectID, CachedThumbnail>()
    private let workerQueue: OperationQueue
    private let inFlightLock = NSLock()
    // All request state and cache writes are protected by inFlightLock.
    private var inFlight: [Key: Decode] = [:]

    private final class Decode {
        let token = UUID()
        let operation: BlockOperation
        var continuations: [UUID: CheckedContinuation<UIImage?, Never>] = [:]

        init(operation: BlockOperation) { self.operation = operation }
    }

    private final class Request: @unchecked Sendable {
        let id = UUID()
        // Accessed only while holding the owning cache's inFlightLock.
        var isCancelled = false
    }

    init(workerQueue: OperationQueue = OperationQueue()) {
        cache.countLimit = 512
        cache.totalCostLimit = 128 * 1_024 * 1_024
        self.workerQueue = workerQueue
        workerQueue.name = "me.riepl.progress.thumbnail-decoding"
        workerQueue.qualityOfService = .userInitiated
        workerQueue.maxConcurrentOperationCount = 4
    }

    func image(
        for objectID: NSManagedObjectID,
        data: Data?,
        priority: Operation.QueuePriority = .veryHigh,
        resolution: Resolution = .grid
    ) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        let key = Key(objectID: objectID, resolution: resolution)
        if let image = cachedImage(for: objectID, resolution: resolution) { return image }

        guard let data else { return nil }
        let request = Request()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                inFlightLock.lock()
                guard !request.isCancelled else {
                    inFlightLock.unlock()
                    continuation.resume(returning: nil)
                    return
                }
                if let image = cachedImage(for: objectID, resolution: resolution) {
                    inFlightLock.unlock()
                    continuation.resume(returning: image)
                    return
                }
                if let decode = inFlight[key] {
                    decode.continuations[request.id] = continuation
                    if priority.rawValue > decode.operation.queuePriority.rawValue {
                        decode.operation.queuePriority = priority
                    }
                    inFlightLock.unlock()
                    return
                }
                let operation = BlockOperation()
                operation.queuePriority = priority
                let decode = Decode(operation: operation)
                let token = decode.token
                decode.continuations[request.id] = continuation
                inFlight[key] = decode
                operation.addExecutionBlock { [self] in
                    let preparedImage: UIImage? = autoreleasepool {
                        guard let image = decodeThumbnailImage(from: data, resolution: resolution) else { return nil }
                        return image.preparingForDisplay() ?? image
                    }
                    finish(for: key, token: token, image: preparedImage)
                }
                inFlightLock.unlock()
                workerQueue.addOperation(operation)
            }
        } onCancel: {
            self.cancel(request, for: key)
        }
    }

    func setPriority(
        _ priority: Operation.QueuePriority,
        for objectID: NSManagedObjectID,
        resolution: Resolution = .grid
    ) {
        inFlightLock.lock()
        inFlight[Key(objectID: objectID, resolution: resolution)]?.operation.queuePriority = priority
        inFlightLock.unlock()
    }

    func cachedImage(for objectID: NSManagedObjectID, resolution: Resolution = .grid) -> UIImage? {
        guard let thumbnail = cache.object(forKey: objectID),
              thumbnail.resolution.rawValue >= resolution.rawValue else { return nil }
        return thumbnail.image
    }

    func removeImage(for objectID: NSManagedObjectID) {
        inFlightLock.lock()
        cache.removeObject(forKey: objectID)
        let keys = inFlight.keys.filter { $0.objectID == objectID }
        let decodes = keys.compactMap { inFlight.removeValue(forKey: $0) }
        for decode in decodes { decode.operation.cancel() }
        inFlightLock.unlock()
        for decode in decodes {
            for continuation in decode.continuations.values { continuation.resume(returning: nil) }
        }
    }

    func removeAllImages() {
        inFlightLock.lock()
        cache.removeAllObjects()
        let decodes = Array(inFlight.values)
        inFlight.removeAll()
        for decode in decodes { decode.operation.cancel() }
        inFlightLock.unlock()
        for decode in decodes {
            for continuation in decode.continuations.values { continuation.resume(returning: nil) }
        }
    }

    private func finish(for key: Key, token: UUID, image: UIImage?) {
        inFlightLock.lock()
        guard let decode = inFlight[key], decode.token == token else {
            inFlightLock.unlock()
            return
        }
        inFlight[key] = nil
        if let image,
           (cache.object(forKey: key.objectID)?.resolution.rawValue ?? 0) <= key.resolution.rawValue {
            cache.setObject(
                CachedThumbnail(image: image, resolution: key.resolution),
                forKey: key.objectID, cost: cacheCost(for: image)
            )
        }
        let continuations = Array(decode.continuations.values)
        inFlightLock.unlock()

        for continuation in continuations {
            continuation.resume(returning: image)
        }
    }

    private func cancel(_ request: Request, for key: Key) {
        inFlightLock.lock()
        request.isCancelled = true
        let decode = inFlight[key]
        let continuation = decode?.continuations.removeValue(forKey: request.id)
        if let decode, decode.continuations.isEmpty {
            inFlight[key] = nil
            decode.operation.cancel()
        }
        inFlightLock.unlock()
        continuation?.resume(returning: nil)
    }

    private func decodeThumbnailImage(from data: Data, resolution: Resolution) -> UIImage? {
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
            return nil
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: resolution.rawValue
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }

    private func cacheCost(for image: UIImage) -> Int {
        let pixelWidth = Int(image.size.width * image.scale)
        let pixelHeight = Int(image.size.height * image.scale)
        return max(pixelWidth * pixelHeight * 4, 1)
    }
}
