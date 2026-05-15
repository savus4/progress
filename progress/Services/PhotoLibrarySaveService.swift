import CoreLocation
import Foundation
import Photos

struct PhotoLibrarySaveItem: Sendable {
    let fullImageAssetName: String?
    let livePhotoImageAssetName: String?
    let livePhotoVideoAssetName: String?
    let captureDate: Date?
    let latitude: Double
    let longitude: Double

    @MainActor
    init(photo: DailyPhoto) {
        fullImageAssetName = photo.fullImageAssetName
        livePhotoImageAssetName = photo.livePhotoImageAssetName
        livePhotoVideoAssetName = photo.livePhotoVideoAssetName
        captureDate = photo.captureDate
        latitude = photo.latitude
        longitude = photo.longitude
    }

    init(item: PhotoDetailItem) {
        fullImageAssetName = item.fullImageAssetName
        livePhotoImageAssetName = item.livePhotoImageAssetName
        livePhotoVideoAssetName = item.livePhotoVideoAssetName
        captureDate = item.captureDate
        latitude = item.latitude
        longitude = item.longitude
    }
}

enum PhotoLibrarySaveError: LocalizedError {
    case noPhotos
    case photoLibraryAccessDenied
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .noPhotos:
            "Please choose at least one photo to save."
        case .photoLibraryAccessDenied:
            "Allow Photos access to save photos to your library."
        case .saveFailed:
            "The photo could not be saved to the Photos library."
        }
    }
}

@MainActor
final class PhotoLibrarySaveService {
    static let shared = PhotoLibrarySaveService()

    private let photoStorageService = PhotoStorageService.shared

    private init() {}

    @discardableResult
    func save(_ photo: DailyPhoto) async throws -> Int {
        try await save([PhotoLibrarySaveItem(photo: photo)])
    }

    @discardableResult
    func save(_ photos: [DailyPhoto]) async throws -> Int {
        try await save(photos.map(PhotoLibrarySaveItem.init(photo:)))
    }

    @discardableResult
    func save(_ item: PhotoLibrarySaveItem) async throws -> Int {
        try await save([item])
    }

    @discardableResult
    func save(_ items: [PhotoLibrarySaveItem]) async throws -> Int {
        guard !items.isEmpty else {
            throw PhotoLibrarySaveError.noPhotos
        }

        let authorizationStatus = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard authorizationStatus == .authorized || authorizationStatus == .limited else {
            throw PhotoLibrarySaveError.photoLibraryAccessDenied
        }

        var resolvedItems: [ResolvedPhotoLibrarySaveItem] = []
        resolvedItems.reserveCapacity(items.count)

        for item in items {
            resolvedItems.append(try await resolvedSaveItem(for: item))
        }

        try await saveResolvedItems(resolvedItems)
        return resolvedItems.count
    }

    private func resolvedSaveItem(for item: PhotoLibrarySaveItem) async throws -> ResolvedPhotoLibrarySaveItem {
        let imageURL: URL
        let videoURL: URL?

        if let livePhotoImageAssetName = item.livePhotoImageAssetName,
           let livePhotoVideoAssetName = item.livePhotoVideoAssetName {
            let resources = try await photoStorageService.loadLivePhotoResources(
                imageAssetName: livePhotoImageAssetName,
                videoAssetName: livePhotoVideoAssetName
            )
            imageURL = resources.imageURL
            videoURL = resources.videoURL
        } else {
            imageURL = try await photoStorageService.prepareStillPhotoShareURL(
                fullImageAssetName: item.fullImageAssetName ?? item.livePhotoImageAssetName
            )
            videoURL = nil
        }

        return ResolvedPhotoLibrarySaveItem(
            imageURL: imageURL,
            videoURL: videoURL,
            captureDate: item.captureDate,
            location: location(for: item)
        )
    }

    private func saveResolvedItems(_ items: [ResolvedPhotoLibrarySaveItem]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                for item in items {
                    let creationRequest = PHAssetCreationRequest.forAsset()
                    creationRequest.creationDate = item.captureDate
                    creationRequest.location = item.location
                    creationRequest.addResource(with: .photo, fileURL: item.imageURL, options: nil)

                    if let videoURL = item.videoURL {
                        creationRequest.addResource(with: .pairedVideo, fileURL: videoURL, options: nil)
                    }
                }
            } completionHandler: { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: PhotoLibrarySaveError.saveFailed)
                }
            }
        }
    }

    private func location(for item: PhotoLibrarySaveItem) -> CLLocation? {
        guard item.latitude != 0 || item.longitude != 0 else { return nil }
        return CLLocation(latitude: item.latitude, longitude: item.longitude)
    }
}

private struct ResolvedPhotoLibrarySaveItem {
    let imageURL: URL
    let videoURL: URL?
    let captureDate: Date?
    let location: CLLocation?
}
