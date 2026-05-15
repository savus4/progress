import Combine
import CoreTransferable
import Foundation
import os
import Photos
import PhotosUI
import SwiftUI

struct PhotoImportAlbum: Identifiable {
    let localIdentifier: String
    let title: String
    let assetCount: Int

    var id: String { localIdentifier }

    var isPrimaryLibraryAlbum: Bool {
        let normalizedTitle = title.lowercased()
        return normalizedTitle == "library" || normalizedTitle == "recents"
    }
}

@MainActor
final class PhotoImportCoordinator: ObservableObject {
    static let shared = PhotoImportCoordinator()

    @Published private(set) var isImporting = false
    @Published private(set) var totalCount = 0
    @Published private(set) var importedCount = 0
    @Published private(set) var duplicateCount = 0
    @Published private(set) var failedCount = 0
    @Published private(set) var statusMessage: String?
    @Published private(set) var smoothedRemainingSeconds: TimeInterval?
    @Published private(set) var completionMessage: String?

    private var importFailureMessages: [String] = []
    private var importTask: Task<Void, Never>?
    private var completionDismissTask: Task<Void, Never>?
    private var importStartedAt: Date?
    private var learnedSecondsPerPhoto: TimeInterval?
    private let importLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "progress", category: "PhotoImport")
    private let importFlushSize = 3
    private let secondsPerPhotoEstimateKey = "photoImportSecondsPerPhotoEstimate"

    var processedCount: Int {
        importedCount + duplicateCount + failedCount
    }

    var shouldShowOverlay: Bool {
        isImporting || completionMessage != nil
    }

    var progressDescription: String {
        let importedSummary = importedCount == 0 ? nil : "\(importedCount) imported"
        let duplicateSummary = duplicateCount == 0 ? nil : "\(duplicateCount) skipped"
        let failureSummary = failedCount == 0 ? nil : "\(failedCount) failed"
        let summaries = [importedSummary, duplicateSummary, failureSummary].compactMap(\.self)

        if summaries.isEmpty {
            return "Importing \(processedCount) of \(totalCount)"
        }

        return "Importing \(processedCount) of \(totalCount) (\(summaries.joined(separator: ", ")))"
    }

    var remainingTimeText: String? {
        guard isImporting, let smoothedRemainingSeconds else { return nil }
        guard smoothedRemainingSeconds > 1 else { return "<1 min left" }

        if smoothedRemainingSeconds < 60 {
            return "<1 min left"
        }

        let minutes = max(1, Int((smoothedRemainingSeconds / 60).rounded(.up)))
        return "~\(minutes) min left"
    }

    private init() {
        let storedEstimate = UserDefaults.standard.double(forKey: secondsPerPhotoEstimateKey)
        if storedEstimate > 0 {
            learnedSecondsPerPhoto = storedEstimate
        }
    }

    func importSelectedPhotos(_ items: [PhotosPickerItem]) {
        beginImport(totalCount: items.count) {
            await self.importItems(items, preserveLivePhotos: true)
        }
    }

    func importSelectedPhotosPrivately(_ items: [PhotosPickerItem]) {
        beginImport(totalCount: items.count) {
            await self.importItems(items, preserveLivePhotos: false)
        }
    }

    func requestImportAlbums() async -> [PhotoImportAlbum] {
        guard !isImporting else { return [] }

        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            statusMessage = "Photos access is required to import an album."
            return []
        }

        return loadImportAlbums()
    }

    func importAlbum(_ album: PhotoImportAlbum) {
        let fetchResult = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [album.localIdentifier], options: nil)
        guard let collection = fetchResult.firstObject else {
            statusMessage = "The selected album is no longer available."
            return
        }

        let assetOptions = PHFetchOptions()
        assetOptions.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        let assets = allObjects(from: PHAsset.fetchAssets(in: collection, options: assetOptions))

        beginImport(totalCount: assets.count) {
            await self.importAssets(assets, preserveLivePhotos: true)
        }
    }

    private func beginImport(totalCount: Int, operation: @escaping @Sendable () async -> Void) {
        guard !isImporting else { return }

        importTask?.cancel()
        completionDismissTask?.cancel()
        isImporting = true
        self.totalCount = totalCount
        importedCount = 0
        duplicateCount = 0
        failedCount = 0
        statusMessage = nil
        completionMessage = nil
        importStartedAt = Date()
        smoothedRemainingSeconds = learnedSecondsPerPhoto.map { $0 * Double(totalCount) }
        importFailureMessages = []

        importTask = Task { @MainActor in
            await operation()
            importTask = nil
        }
    }

    private func photoAsset(for item: PhotosPickerItem) -> PHAsset? {
        guard let identifier = item.itemIdentifier else { return nil }
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        return fetchResult.firstObject
    }

    private func loadLivePhotoImportResources(for asset: PHAsset) async throws -> (imageData: Data, videoURL: URL)? {
        guard asset.mediaSubtypes.contains(.photoLive) else { return nil }

        let resources = PHAssetResource.assetResources(for: asset)
        guard let imageResource = resources.first(where: { $0.type == .photo || $0.type == .fullSizePhoto }),
              let videoResource = resources.first(where: { $0.type == .pairedVideo }) else {
            return nil
        }

        let imageURL = try await writeResourceToTemporaryFile(imageResource)
        defer {
            try? FileManager.default.removeItem(at: imageURL)
        }
        let imageData = try Data(contentsOf: imageURL)
        let videoURL = try await writeResourceToTemporaryFile(videoResource)

        return (imageData: imageData, videoURL: videoURL)
    }

    private func loadStillPhotoImportPayload(for asset: PHAsset) async throws -> ImportedPhotoPayload? {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let imageResource = resources.first(where: { $0.type == .photo || $0.type == .fullSizePhoto }) else {
            return try await loadStillPhotoImportPayloadViaImageManager(for: asset)
        }

        do {
            let imageURL = try await writeResourceToTemporaryFile(imageResource)
            defer {
                try? FileManager.default.removeItem(at: imageURL)
            }

            let imageData = try Data(contentsOf: imageURL)
            return ImportedPhotoPayload(imageData: imageData)
        } catch {
            if isTransientCloudImportError(error) {
                return try await loadStillPhotoImportPayloadViaImageManager(for: asset)
            }
            throw error
        }
    }

    private func loadImportPayload(for asset: PHAsset, preserveLivePhotos: Bool) async throws -> ImportedPhotoPayload? {
        guard asset.mediaType == .image else { return nil }

        if preserveLivePhotos,
           let livePhotoImport = try await loadLivePhotoImportResources(for: asset) {
            return ImportedPhotoPayload(
                imageData: livePhotoImport.imageData,
                livePhotoVideoURL: livePhotoImport.videoURL
            )
        }

        return try await loadStillPhotoImportPayload(for: asset)
    }

    private func loadAlbumImportPayload(for asset: PHAsset, preserveLivePhotos: Bool) async throws -> ImportedPhotoPayload? {
        guard asset.mediaType == .image else { return nil }

        if preserveLivePhotos {
            do {
                if let livePhotoImport = try await loadLivePhotoImportResources(for: asset) {
                    return ImportedPhotoPayload(
                        imageData: livePhotoImport.imageData,
                        livePhotoVideoURL: livePhotoImport.videoURL
                    )
                }
            } catch {
                guard !isTransientCloudImportError(error) else {
                    return try await loadStillPhotoImportPayloadViaImageManager(for: asset)
                }
                throw error
            }
        }

        if let payload = try await loadStillPhotoImportPayloadViaImageManager(for: asset) {
            return payload
        }

        return try await loadStillPhotoImportPayload(for: asset)
    }

    private func loadImportPayload(for item: PhotosPickerItem, preserveLivePhotos: Bool) async throws -> ImportedPhotoPayload? {
        if let asset = photoAsset(for: item),
           let payload = try await loadImportPayload(for: asset, preserveLivePhotos: preserveLivePhotos) {
            return payload
        }

        guard let importedFile = try await item.loadTransferable(type: ImportedPickerImageFile.self) else {
            return nil
        }

        defer {
            try? FileManager.default.removeItem(at: importedFile.fileURL)
        }

        let imageData = try Data(contentsOf: importedFile.fileURL)
        return ImportedPhotoPayload(imageData: imageData)
    }

    private func writeResourceToTemporaryFile(_ resource: PHAssetResource) async throws -> URL {
        let originalExtension = URL(fileURLWithPath: resource.originalFilename).pathExtension
        var destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)

        if !originalExtension.isEmpty {
            destinationURL.appendPathExtension(originalExtension)
        }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        let maximumAttempts = 3
        for attempt in 1...maximumAttempts {
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    PHAssetResourceManager.default().writeData(for: resource, toFile: destinationURL, options: options) { error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: ())
                        }
                    }
                }
                return destinationURL
            } catch {
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try? FileManager.default.removeItem(at: destinationURL)
                }

                guard attempt < maximumAttempts, isTransientCloudImportError(error) else {
                    throw error
                }

                try? await Task.sleep(for: .milliseconds(400 * attempt))
            }
        }

        return destinationURL
    }

    private func loadStillPhotoImportPayloadViaImageManager(for asset: PHAsset) async throws -> ImportedPhotoPayload? {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .none
        options.version = .current
        options.isSynchronous = false

        return try await withCheckedThrowingContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                    return
                }

                if (info?[PHImageCancelledKey] as? NSNumber)?.boolValue == true {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                guard let data else {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: ImportedPhotoPayload(imageData: data))
            }
        }
    }

    private func isTransientCloudImportError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "CloudPhotoLibraryErrorDomain" || nsError.domain == NSURLErrorDomain
    }

    private func importItems(_ items: [PhotosPickerItem], preserveLivePhotos: Bool) async {
        let clock = ContinuousClock()
        let startedAt = clock.now

        var pendingPayloads: [ImportedPhotoPayload] = []
        pendingPayloads.reserveCapacity(importFlushSize)

        for item in items {
            do {
                guard let payload = try await loadImportPayload(for: item, preserveLivePhotos: preserveLivePhotos) else {
                    await recordImportFailure(
                        stage: "picker-transfer",
                        itemIdentifier: item.itemIdentifier,
                        message: "No importable image payload was returned."
                    )
                    continue
                }
                pendingPayloads.append(payload)
            } catch {
                let stage = preserveLivePhotos ? "item-load" : "private-item-load"
                await recordImportFailure(
                    stage: stage,
                    itemIdentifier: item.itemIdentifier,
                    message: error.localizedDescription
                )
            }

            if pendingPayloads.count >= importFlushSize {
                await flushImportedPayloads(&pendingPayloads)
            }
        }

        if !pendingPayloads.isEmpty {
            await flushImportedPayloads(&pendingPayloads)
        }

        await finishImportSession(
            totalCount: items.count,
            preserveLivePhotos: preserveLivePhotos,
            startedAt: startedAt,
            clock: clock,
            logPrefix: "Settings import finished."
        )
    }

    private func importAssets(_ assets: [PHAsset], preserveLivePhotos: Bool) async {
        let clock = ContinuousClock()
        let startedAt = clock.now

        var pendingPayloads: [ImportedPhotoPayload] = []
        pendingPayloads.reserveCapacity(importFlushSize)

        for asset in assets {
            do {
                guard let payload = try await loadAlbumImportPayload(for: asset, preserveLivePhotos: preserveLivePhotos) else {
                    await recordImportFailure(
                        stage: "album-asset-load",
                        itemIdentifier: asset.localIdentifier,
                        message: "No importable image payload was returned."
                    )
                    continue
                }
                pendingPayloads.append(payload)
            } catch {
                let stage = preserveLivePhotos ? "album-item-load" : "album-private-item-load"
                await recordImportFailure(
                    stage: stage,
                    itemIdentifier: asset.localIdentifier,
                    message: error.localizedDescription
                )
            }

            if pendingPayloads.count >= importFlushSize {
                await flushImportedPayloads(&pendingPayloads)
            }
        }

        if !pendingPayloads.isEmpty {
            await flushImportedPayloads(&pendingPayloads)
        }

        await finishImportSession(
            totalCount: assets.count,
            preserveLivePhotos: preserveLivePhotos,
            startedAt: startedAt,
            clock: clock,
            logPrefix: "Album import finished."
        )
    }

    private func finishImportSession(
        totalCount: Int,
        preserveLivePhotos: Bool,
        startedAt: ContinuousClock.Instant,
        clock: ContinuousClock,
        logPrefix: String
    ) async {
        let elapsed = startedAt.duration(to: clock.now)
        let imported = importedCount
        let duplicates = duplicateCount
        let failed = failedCount
        let status: String

        isImporting = false
        smoothedRemainingSeconds = nil
        updateLearnedSecondsPerPhoto()

        if failed == 0 {
            let baseMessage = preserveLivePhotos
                ? "Imported \(imported) photo\(imported == 1 ? "" : "s")."
                : "Imported \(imported) photo\(imported == 1 ? "" : "s") using private mode."
            if duplicates > 0 {
                status = "\(baseMessage) Skipped \(duplicates) duplicate picture\(duplicates == 1 ? "" : "s")."
            } else {
                status = baseMessage
            }
        } else {
            let failureSummary = importFailureMessages.prefix(3).joined(separator: " | ")
            let prefix = preserveLivePhotos
                ? "Imported \(imported), failed \(failed)."
                : "Private import: imported \(imported), failed \(failed)."
            let duplicateSummary = duplicates > 0
                ? " Skipped \(duplicates) duplicate picture\(duplicates == 1 ? "" : "s")."
                : ""
            let summary = prefix + duplicateSummary
            status = failureSummary.isEmpty ? summary : "\(summary) \(failureSummary)"
        }

        statusMessage = status
        showCompletionMessage(status)

        importLogger.log(
            "\(logPrefix, privacy: .public) total=\(totalCount, privacy: .public) imported=\(imported, privacy: .public) duplicates=\(duplicates, privacy: .public) failed=\(failed, privacy: .public) elapsed=\(String(describing: elapsed), privacy: .public)"
        )
    }

    private func loadImportAlbums() -> [PhotoImportAlbum] {
        let assetOptions = PHFetchOptions()
        assetOptions.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)

        var albums: [PhotoImportAlbum] = []

        func appendAlbums(from fetchResult: PHFetchResult<PHAssetCollection>) {
            fetchResult.enumerateObjects { collection, _, _ in
                let count = PHAsset.fetchAssets(in: collection, options: assetOptions).count
                guard count > 0 else { return }
                albums.append(
                    PhotoImportAlbum(
                        localIdentifier: collection.localIdentifier,
                        title: collection.localizedTitle ?? "Album",
                        assetCount: count
                    )
                )
            }
        }

        appendAlbums(from: PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumUserLibrary, options: nil))
        appendAlbums(from: PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil))

        let smartAlbums = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .any, options: nil)
        smartAlbums.enumerateObjects { collection, _, _ in
            guard collection.assetCollectionSubtype == .smartAlbumFavorites ||
                    collection.assetCollectionSubtype == .smartAlbumRecentlyAdded ||
                    collection.assetCollectionSubtype == .smartAlbumLivePhotos else {
                return
            }

            let count = PHAsset.fetchAssets(in: collection, options: assetOptions).count
            guard count > 0 else { return }
            albums.append(
                PhotoImportAlbum(
                    localIdentifier: collection.localIdentifier,
                    title: collection.localizedTitle ?? "Album",
                    assetCount: count
                )
            )
        }

        var seenIdentifiers: Set<String> = []
        return albums
            .filter { seenIdentifiers.insert($0.localIdentifier).inserted }
            .sorted { lhs, rhs in
                if lhs.isPrimaryLibraryAlbum && !rhs.isPrimaryLibraryAlbum {
                    return true
                }
                if rhs.isPrimaryLibraryAlbum && !lhs.isPrimaryLibraryAlbum {
                    return false
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    private func flushImportedPayloads(_ payloads: inout [ImportedPhotoPayload]) async {
        let chunk = payloads
        payloads.removeAll(keepingCapacity: true)

        let result = await PhotoStorageService.shared.saveImportedPhotos(chunk, batchSize: importFlushSize)
        importedCount += result.importedCount
        duplicateCount += result.duplicateCount
        failedCount += result.failedCount
        updateRemainingTimeEstimate()
        importFailureMessages.append(contentsOf: result.failureMessages)
        if importFailureMessages.count > 20 {
            importFailureMessages = Array(importFailureMessages.prefix(20))
        }
    }

    private func recordImportFailure(stage: String, itemIdentifier: String?, message: String) async {
        let identifier = itemIdentifier ?? "unknown"
        let logMessage = "\(stage) item=\(identifier): \(message)"
        importLogger.error("\(logMessage, privacy: .public)")

        failedCount += 1
        updateRemainingTimeEstimate()

        if importFailureMessages.count < 20 {
            importFailureMessages.append(logMessage)
        }
    }

    private func updateRemainingTimeEstimate() {
        guard isImporting, processedCount > 0 else { return }
        guard let importStartedAt else { return }

        let elapsedSeconds = Date().timeIntervalSince(importStartedAt)
        guard elapsedSeconds > 0 else { return }

        let currentSecondsPerPhoto = elapsedSeconds / Double(processedCount)
        let blendedSecondsPerPhoto = if let learnedSecondsPerPhoto {
            (learnedSecondsPerPhoto * 0.65) + (currentSecondsPerPhoto * 0.35)
        } else {
            currentSecondsPerPhoto
        }

        learnedSecondsPerPhoto = blendedSecondsPerPhoto
        smoothedRemainingSeconds = max(0, Double(max(totalCount - processedCount, 0)) * blendedSecondsPerPhoto)
    }

    private func updateLearnedSecondsPerPhoto() {
        guard processedCount > 0, let importStartedAt else { return }

        let elapsedSeconds = Date().timeIntervalSince(importStartedAt)
        guard elapsedSeconds > 0 else { return }

        let finalSecondsPerPhoto = elapsedSeconds / Double(processedCount)
        let nextEstimate = if let learnedSecondsPerPhoto {
            (learnedSecondsPerPhoto * 0.75) + (finalSecondsPerPhoto * 0.25)
        } else {
            finalSecondsPerPhoto
        }

        learnedSecondsPerPhoto = nextEstimate
        UserDefaults.standard.set(nextEstimate, forKey: secondsPerPhotoEstimateKey)
    }

    private func showCompletionMessage(_ message: String) {
        completionDismissTask?.cancel()
        completionMessage = message
        completionDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            completionMessage = nil
            completionDismissTask = nil
        }
    }
}

private struct ImportedPickerImageFile: Transferable {
    let fileURL: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            Self(fileURL: try ImportedPickerFileCopier.makeTemporaryCopy(of: received.file))
        }
    }
}

private enum ImportedPickerFileCopier {
    nonisolated static func makeTemporaryCopy(of sourceURL: URL) throws -> URL {
        let originalExtension = sourceURL.pathExtension
        var destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)

        if !originalExtension.isEmpty {
            destinationURL.appendPathExtension(originalExtension)
        }

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }
}

private func allObjects<ObjectType: AnyObject>(from fetchResult: PHFetchResult<ObjectType>) -> [ObjectType] {
    var objects: [ObjectType] = []
    objects.reserveCapacity(fetchResult.count)
    fetchResult.enumerateObjects { object, _, _ in
        objects.append(object)
    }
    return objects
}
