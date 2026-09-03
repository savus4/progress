import AVFoundation
import CloudKit
import CoreData
import Foundation
import Testing
import UIKit
@testable import progress

nonisolated private let runsCloudKitIntegrationTests = ProcessInfo.processInfo.environment["RUN_CLOUDKIT_TESTS"] == "1"

@Suite("Core Functionality Tests")
struct ProgressCoreFunctionalityTests {
    @Test("AlignmentGuide default values are stable")
    func alignmentGuideDefaultValues() {
        #expect(AlignmentGuide.default.eyeLinePosition == 0.35)
        #expect(AlignmentGuide.default.mouthLinePosition == 0.65)
    }

    @MainActor
    @Test("AlignmentGuide supports Codable round-trip")
    func alignmentGuideCodableRoundTrip() throws {
        let original = AlignmentGuide(eyeLinePosition: 0.4, mouthLinePosition: 0.7)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AlignmentGuide.self, from: encoded)

        #expect(decoded.eyeLinePosition == original.eyeLinePosition)
        #expect(decoded.mouthLinePosition == original.mouthLinePosition)
    }

    @MainActor
    @Test("PhotoExportMetadata encodes expected payload")
    func photoExportMetadataEncoding() throws {
        let metadata = PhotoExportMetadata(
            id: "abc-123",
            captureDateISO8601: "2026-03-24T08:30:00Z",
            createdAtISO8601: "2026-03-24T08:31:00Z",
            modifiedAtISO8601: "2026-03-24T08:32:00Z",
            latitude: 48.1372,
            longitude: 11.5756,
            locationName: "Munich",
            fullImageAssetName: "full.heic",
            livePhotoImageAssetName: "live.heic",
            livePhotoVideoAssetName: "live.mov"
        )

        let encoded = try JSONEncoder().encode(metadata)
        let json = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        #expect(json["id"] as? String == "abc-123")
        #expect(json["captureDateISO8601"] as? String == "2026-03-24T08:30:00Z")
        #expect(json["locationName"] as? String == "Munich")
        #expect(json["latitude"] as? Double == 48.1372)
        #expect(json["longitude"] as? Double == 11.5756)
        #expect(json["fullImageAssetName"] as? String == "full.heic")
        #expect(json["livePhotoImageAssetName"] as? String == "live.heic")
        #expect(json["livePhotoVideoAssetName"] as? String == "live.mov")
    }

    @Test("CameraService prefers HEVC when supported")
    func cameraServicePrefersHEVCWhenSupported() {
        #expect(CameraService.preferredCodec(from: [.jpeg, .hevc]) == .hevc)
    }

    @Test("CameraService falls back when HEVC is unavailable")
    func cameraServiceFallsBackWhenHEVCUnavailable() {
        #expect(CameraService.preferredCodec(from: [.jpeg]) == nil)
    }

    @Test("CameraService uses portrait photo aspect from dimensions")
    func cameraServiceUsesPortraitPhotoAspectFromDimensions() {
        #expect(CameraService.portraitPhotoAspectRatio(for: CMVideoDimensions(width: 4032, height: 3024)) == 0.75)
        #expect(CameraService.portraitPhotoAspectRatio(for: CMVideoDimensions(width: 3024, height: 4032)) == 0.75)
    }

    @Test("CameraService falls back to stable portrait photo aspect for invalid dimensions")
    func cameraServiceAspectFallsBackForInvalidDimensions() {
        #expect(CameraService.portraitPhotoAspectRatio(for: CMVideoDimensions(width: 0, height: 0)) == CameraService.defaultPortraitPhotoAspectRatio)
    }

    @Test("Reminder times are clamped, sorted, deduplicated, and capped")
    func dailyReminderLoadSanitizesPersistedData() throws {
        let key = "dailyPhotoReminderTimes"
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let persisted: [DailyReminderTime] = [
            .init(id: UUID(), hour: 10, minute: 15),
            .init(id: UUID(), hour: 10, minute: 15),
            .init(id: UUID(), hour: 26, minute: 80),
            .init(id: UUID(), hour: -1, minute: -2),
            .init(id: UUID(), hour: 9, minute: 30),
            .init(id: UUID(), hour: 18, minute: 45),
            .init(id: UUID(), hour: 22, minute: 0)
        ]
        let encoded = try JSONEncoder().encode(persisted)
        UserDefaults.standard.set(encoded, forKey: key)

        let times = DailyReminderNotificationService.shared.loadReminderTimes()
        #expect(times.count == DailyReminderNotificationService.maxRemindersPerDay)
        #expect(times[0].hour == 0)
        #expect(times[0].minute == 0)
        #expect(times[1].hour == 9)
        #expect(times[1].minute == 30)
        #expect(times[2].hour == 10)
        #expect(times[2].minute == 15)
    }

    @Test("Daily reminder notification payload recognition is strict")
    func dailyReminderPayloadRecognition() {
        let valid: [AnyHashable: Any] = [
            DailyReminderNotificationService.notificationUserInfoDestinationKey:
                DailyReminderNotificationService.notificationCameraDestinationValue,
            DailyReminderNotificationService.notificationUserInfoSourceKey:
                DailyReminderNotificationService.notificationSourceValue
        ]

        let wrongDestination: [AnyHashable: Any] = [
            DailyReminderNotificationService.notificationUserInfoDestinationKey: "grid",
            DailyReminderNotificationService.notificationUserInfoSourceKey:
                DailyReminderNotificationService.notificationSourceValue
        ]

        #expect(DailyReminderNotificationService.shared.isDailyReminderNotification(userInfo: valid))
        #expect(DailyReminderNotificationService.shared.isDailyReminderNotification(userInfo: wrongDestination) == false)
    }

    @Test("Location cache returns value at rounded coordinate precision")
    func locationNameCacheUsesRoundedCoordinates() async {
        let latitude = 12.34564
        let longitude = -98.76544
        let nearbyLatitude = 12.345641
        let nearbyLongitude = -98.765439

        await LocationNameCacheService.shared.setCachedName("Test Place", for: latitude, longitude: longitude)
        let cached = await LocationNameCacheService.shared.cachedName(for: nearbyLatitude, longitude: nearbyLongitude)

        #expect(cached == "Test Place")
    }

    @MainActor
    @Test("Notification navigation request token can be requested and consumed")
    func notificationNavigationCoordinatorTokenLifecycle() {
        let coordinator = NotificationNavigationCoordinator.shared
        coordinator.consumeCameraOpenRequest()
        #expect(coordinator.cameraOpenRequestToken == nil)

        coordinator.requestCameraOpenFromNotification()
        let firstToken = coordinator.cameraOpenRequestToken
        #expect(firstToken != nil)

        coordinator.requestCameraOpenFromNotification()
        #expect(coordinator.cameraOpenRequestToken != nil)
        #expect(coordinator.cameraOpenRequestToken != firstToken)

        coordinator.consumeCameraOpenRequest()
        #expect(coordinator.cameraOpenRequestToken == nil)
    }

    @MainActor
    @Test("Thumbnail generation from UIImage returns compressed image data")
    func thumbnailGenerationFromImage() {
        let input = makeImage(size: CGSize(width: 1200, height: 800), color: .red)
        let data = ThumbnailService.shared.generateThumbnail(from: input)

        #expect(data != nil)
        let image = UIImage(data: data ?? Data())
        #expect(image != nil)
    }

    @MainActor
    @Test("Thumbnail generation from encoded bytes returns compressed image data")
    func thumbnailGenerationFromEncodedData() {
        let input = makeImage(size: CGSize(width: 800, height: 1200), color: .blue)
        let sourceData = input.jpegData(compressionQuality: 1.0)
        let thumbnailData = ThumbnailService.shared.generateThumbnail(from: sourceData ?? Data())

        #expect(thumbnailData != nil)
        let image = UIImage(data: thumbnailData ?? Data())
        #expect(image != nil)
    }

    @MainActor
    @Test("DecodedThumbnailCache returns cached prepared image")
    func decodedThumbnailCacheReturnsCachedPreparedImage() async throws {
        let context = PersistenceController(inMemory: true).container.viewContext
        let photo = DailyPhoto(context: context)
        photo.id = UUID()
        try context.obtainPermanentIDs(for: [photo])

        let input = makeImage(size: CGSize(width: 900, height: 700), color: .purple)
        let thumbnailData = try #require(ThumbnailService.shared.generateThumbnail(from: input))

        let firstImage = try #require(
            await DecodedThumbnailCache.shared.image(for: photo.objectID, data: thumbnailData)
        )
        let cachedImage = try #require(DecodedThumbnailCache.shared.cachedImage(for: photo.objectID))
        let secondImage = try #require(
            await DecodedThumbnailCache.shared.image(for: photo.objectID, data: thumbnailData)
        )

        #expect(firstImage === cachedImage)
        #expect(secondImage === cachedImage)
    }

    @MainActor
    @Test("DecodedThumbnailCache coalesces duplicate decode requests")
    func decodedThumbnailCacheCoalescesDuplicateDecodeRequests() async throws {
        let context = PersistenceController(inMemory: true).container.viewContext
        let photo = DailyPhoto(context: context)
        photo.id = UUID()
        try context.obtainPermanentIDs(for: [photo])

        let input = makeImage(size: CGSize(width: 1200, height: 1200), color: .brown)
        let thumbnailData = try #require(ThumbnailService.shared.generateThumbnail(from: input))
        let objectID = photo.objectID

        async let first = DecodedThumbnailCache.shared.image(for: objectID, data: thumbnailData)
        async let second = DecodedThumbnailCache.shared.image(for: objectID, data: thumbnailData)
        let (firstResult, secondResult) = await (first, second)
        let firstImage = try #require(firstResult)
        let secondImage = try #require(secondResult)

        #expect(firstImage === secondImage)
    }

    @MainActor
    @Test("CloudKitService caches image bytes and resolves asset URL")
    func cloudKitCachesImageDataAndLoadsURL() async throws {
        let image = makeImage(size: CGSize(width: 320, height: 320), color: .green)
        let imageData = try #require(image.jpegData(compressionQuality: 0.9))
        let assetName = "\(UUID().uuidString).jpg"

        _ = try CloudKitService.shared.stageAssetData(imageData, named: assetName)
        let assetURL = try await CloudKitService.shared.loadAssetURL(named: assetName)
        defer { CloudKitService.shared.deleteAsset(named: assetName) }

        #expect(FileManager.default.fileExists(atPath: assetURL.path))
        let loadedData = try Data(contentsOf: assetURL)
        #expect(loadedData == imageData)
    }

    @Test(
        "CloudKitService throws for unknown remote asset names",
        .enabled(if: runsCloudKitIntegrationTests, "Set RUN_CLOUDKIT_TESTS=1 with an authenticated iCloud simulator")
    )
    func cloudKitThrowsForMissingAssetURL() async {
        do {
            _ = try await CloudKitService.shared.loadAssetURL(named: "\(UUID().uuidString).missing")
            Issue.record("Expected CloudKitError.assetNotFound")
        } catch let error as CloudKitError {
            switch error {
            case .assetNotFound:
                break
            default:
                Issue.record("Expected CloudKitError.assetNotFound but got \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @MainActor
    @Test("PhotoStorageService saves imported still photo into Core Data and asset store")
    func photoStorageSaveImportedPhoto() async throws {
        let context = PersistenceController(inMemory: true).container.viewContext
        let image = makeImage(size: CGSize(width: 640, height: 480), color: .orange)
        let imageData = try #require(image.jpegData(compressionQuality: 0.9))

        let objectID = try await PhotoStorageService.shared.saveImportedPhoto(
            imageData: imageData,
            context: context,
            enqueuesPendingUpload: false
        )
        let photo = try #require(context.existingObject(with: objectID) as? DailyPhoto)
        let assetName = try #require(photo.fullImageAssetName)
        let assetURL = try await CloudKitService.shared.loadAssetURL(named: assetName)
        defer { try? FileManager.default.removeItem(at: assetURL) }

        #expect(photo.id != nil)
        #expect(photo.captureDate != nil)
        #expect(photo.thumbnailData != nil)
        #expect(FileManager.default.fileExists(atPath: assetURL.path))
    }

    @MainActor
    @Test("PhotoStorageService keeps local-mode originals in device backup")
    func photoStorageLocalModeOriginalsAreBackupIncluded() async throws {
        ICloudAvailabilityMonitor.shared.setStateForTesting(.unavailable("Testing local mode"))
        defer {
            ICloudAvailabilityMonitor.shared.setStateForTesting(.available)
            ICloudAvailabilityMonitor.shared.setStateForTesting(nil)
        }

        let context = PersistenceController(inMemory: true).container.viewContext
        let image = makeImage(size: CGSize(width: 640, height: 480), color: .orange)
        let imageData = try #require(image.jpegData(compressionQuality: 0.9))

        let objectID = try await PhotoStorageService.shared.saveImportedPhoto(
            imageData: imageData,
            context: context,
            enqueuesPendingUpload: false
        )
        let photo = try #require(context.existingObject(with: objectID) as? DailyPhoto)
        let assetName = try #require(photo.fullImageAssetName)
        let assetURL = try #require(CloudKitService.shared.stagedAssetURL(named: assetName))
        defer { CloudKitService.shared.deleteAsset(named: assetName) }

        let values = try assetURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == false)
    }

    @Test("ICloudAvailabilityMonitor classifies disabled iCloud errors")
    func iCloudAvailabilityClassifiesDisabledErrors() {
        #expect(ICloudAvailabilityMonitor.isUnavailableCloudKitError(CKError(.notAuthenticated)))
        #expect(ICloudAvailabilityMonitor.isUnavailableCloudKitError(CKError(.permissionFailure)))
        #expect(!ICloudAvailabilityMonitor.isUnavailableCloudKitError(CKError(.quotaExceeded)))
    }

    @MainActor
    @Test("PhotoStorageService reuses the still asset for imported Live Photos")
    func photoStorageReusesStillAssetForImportedLivePhoto() async throws {
        let context = PersistenceController(inMemory: true).container.viewContext
        let image = makeImage(size: CGSize(width: 640, height: 480), color: .cyan)
        let imageData = try #require(image.jpegData(compressionQuality: 0.9))

        let videoURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        try Data([0x10, 0x20, 0x30]).write(to: videoURL)
        defer { try? FileManager.default.removeItem(at: videoURL) }

        let objectID = try await PhotoStorageService.shared.saveImportedLivePhoto(
            imageData: imageData,
            videoURL: videoURL,
            context: context,
            enqueuesPendingUpload: false
        )
        let photo = try #require(context.existingObject(with: objectID) as? DailyPhoto)

        let fullImageAssetName = try #require(photo.fullImageAssetName)
        let liveImageAssetName = try #require(photo.livePhotoImageAssetName)
        let liveVideoAssetName = try #require(photo.livePhotoVideoAssetName)
        defer {
            CloudKitService.shared.deleteAsset(named: fullImageAssetName)
            CloudKitService.shared.deleteAsset(named: liveVideoAssetName)
        }

        #expect(fullImageAssetName == liveImageAssetName)
        #expect((photo.value(forKey: "livePhotoImageData") as? Data) == nil)
        #expect((photo.value(forKey: "fullImageData") as? Data) == nil)
    }

    @MainActor
    @Test("PhotoStorageService reuses the still asset for captured Live Photos")
    func photoStorageReusesStillAssetForCapturedLivePhoto() async throws {
        let context = PersistenceController(inMemory: true).container.viewContext
        let image = makeImage(size: CGSize(width: 640, height: 480), color: .magenta)
        let livePhotoImageData = try #require(image.jpegData(compressionQuality: 0.9))

        let videoURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        try Data([0x40, 0x50, 0x60]).write(to: videoURL)
        defer { try? FileManager.default.removeItem(at: videoURL) }

        let objectID = try await PhotoStorageService.shared.savePhoto(
            image: image,
            imageData: nil,
            livePhotoImageData: livePhotoImageData,
            livePhotoVideoURL: videoURL,
            location: nil,
            context: context,
            enqueuesPendingUpload: false
        )
        let photo = try #require(context.existingObject(with: objectID) as? DailyPhoto)

        let fullImageAssetName = try #require(photo.fullImageAssetName)
        let liveImageAssetName = try #require(photo.livePhotoImageAssetName)
        let liveVideoAssetName = try #require(photo.livePhotoVideoAssetName)
        defer {
            CloudKitService.shared.deleteAsset(named: fullImageAssetName)
            CloudKitService.shared.deleteAsset(named: liveVideoAssetName)
        }

        #expect(fullImageAssetName == liveImageAssetName)
        #expect((photo.value(forKey: "livePhotoImageData") as? Data) == nil)
        #expect((photo.value(forKey: "fullImageData") as? Data) == nil)
    }

    @MainActor
    @Test("PhotoStorageService skips exact duplicate imports and reports duplicate count")
    func photoStorageSkipsExactDuplicateImports() async throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let image = makeImage(size: CGSize(width: 640, height: 480), color: .purple)
        let imageData = try #require(image.jpegData(compressionQuality: 0.9))

        let firstResult = await PhotoStorageService.shared.saveImportedPhotos(
            [ImportedPhotoPayload(imageData: imageData)],
            context: context,
            enqueuesPendingUploads: false
        )
        #expect(firstResult.importedCount == 1)
        #expect(firstResult.duplicateCount == 0)
        #expect(firstResult.failedCount == 0)

        let secondResult = await PhotoStorageService.shared.saveImportedPhotos(
            [ImportedPhotoPayload(imageData: imageData)],
            context: context,
            enqueuesPendingUploads: false
        )
        #expect(secondResult.importedCount == 0)
        #expect(secondResult.duplicateCount == 1)
        #expect(secondResult.failedCount == 0)

        let request = DailyPhoto.fetchRequest()
        let storedCount = try context.count(for: request)
        #expect(storedCount == 1)
    }

    @MainActor
    @Test("PhotoStorageService returns still photo share URL")
    func photoStoragePrepareStillShareURL() async throws {
        let context = PersistenceController(inMemory: true).container.viewContext
        let photo = DailyPhoto(context: context)
        photo.id = UUID()

        let imageData = Data([0x01, 0x02, 0x03])
        let fileName = "\(UUID().uuidString).jpg"
        _ = try CloudKitService.shared.stageAssetData(imageData, named: fileName)
        defer { CloudKitService.shared.deleteAsset(named: fileName) }

        photo.fullImageAssetName = fileName
        let shareURL = try await PhotoStorageService.shared.prepareStillPhotoShareURL(for: photo)
        #expect(shareURL.lastPathComponent == fileName)
    }

    @MainActor
    @Test("CloudKitService returns a stable readable URL for staged assets")
    func cloudKitServiceReturnsStableReadableURLForStagedAsset() async throws {
        let assetName = "\(UUID().uuidString).jpg"
        let imageData = Data([0x10, 0x20, 0x30, 0x40])
        let stagedURL = try CloudKitService.shared.stageAssetData(imageData, named: assetName)
        let readableURL = try await CloudKitService.shared.loadAssetURL(named: assetName)
        defer {
            CloudKitService.shared.deleteAsset(named: assetName)
            try? FileManager.default.removeItem(at: readableURL)
            try? FileManager.default.removeItem(at: readableURL.deletingLastPathComponent())
        }

        #expect(readableURL != stagedURL)
        #expect(readableURL.lastPathComponent == assetName)
        #expect(FileManager.default.fileExists(atPath: readableURL.path))

        let restoredData = try Data(contentsOf: readableURL)
        #expect(restoredData == imageData)
    }

    @MainActor
    @Test("CloudKitService reuses materialized readable URL for fetched assets")
    func cloudKitServiceReusesReadableURLForFetchedAsset() async throws {
        let imageData = Data([0x55, 0x66, 0x77, 0x88])
        let assetName = "\(UUID().uuidString).jpg"
        _ = try CloudKitService.shared.stageAssetData(imageData, named: assetName)
        defer { CloudKitService.shared.deleteAsset(named: assetName) }

        let firstURL = try await CloudKitService.shared.loadAssetURL(named: assetName)
        let secondURL = try await CloudKitService.shared.loadAssetURL(named: assetName)

        #expect(firstURL == secondURL)
        #expect(firstURL.lastPathComponent == assetName)
        let restoredData = try Data(contentsOf: secondURL)
        #expect(restoredData == imageData)
    }

    @MainActor
    @Test(
        "PhotoStorageService restores missing still asset from CloudKit",
        .enabled(if: runsCloudKitIntegrationTests, "Set RUN_CLOUDKIT_TESTS=1 with an authenticated iCloud simulator")
    )
    func photoStorageRestoresMissingStillAssetFromCloudKit() async throws {
        let context = PersistenceController(inMemory: true).container.viewContext
        let photo = DailyPhoto(context: context)
        photo.id = UUID()

        let imageData = Data([0x11, 0x22, 0x33, 0x44])
        let fileName = try await CloudKitService.shared.saveImageDataAsset(imageData, fileExtension: "jpg")
        photo.fullImageAssetName = fileName

        let restoredURL = try await PhotoStorageService.shared.prepareStillPhotoShareURL(for: photo)
        defer { try? FileManager.default.removeItem(at: restoredURL) }

        #expect(restoredURL.lastPathComponent == fileName)
        #expect(FileManager.default.fileExists(atPath: restoredURL.path))
        let restoredData = try Data(contentsOf: restoredURL)
        #expect(restoredData == imageData)
    }

    @MainActor
    @Test("PhotoStorageService has no pending payload backfill in metadata-only architecture")
    func photoStorageBackfillsMissingSyncedPayloadData() async throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let beforeCount = await PhotoStorageService.shared.countPhotosMissingSyncedPayloads(context: context)
        #expect(beforeCount == 0)

        let result = await PhotoStorageService.shared.backfillMissingSyncedPayloads(context: context)
        #expect(result.scannedCount == 0)
        #expect(result.migratedCount == 0)
        #expect(result.missingAssetCount == 0)
        #expect(result.failedCount == 0)

        let afterCount = await PhotoStorageService.shared.countPhotosMissingSyncedPayloads(context: context)
        #expect(afterCount == 0)
    }

    @MainActor
    @Test("PhotoStorageService keeps original payload bytes out of Core Data")
    func photoStorageKeepsOriginalPayloadBytesOutOfCoreData() async throws {
        let context = PersistenceController(inMemory: true).container.viewContext
        let image = makeImage(size: CGSize(width: 900, height: 600), color: .brown)
        let imageData = try #require(image.jpegData(compressionQuality: 0.9))

        let objectID = try await PhotoStorageService.shared.saveImportedPhoto(
            imageData: imageData,
            context: context,
            enqueuesPendingUpload: false
        )
        let photo = try #require(context.existingObject(with: objectID) as? DailyPhoto)

        #expect(photo.fullImageAssetName != nil)
        #expect((photo.value(forKey: "fullImageData") as? Data) == nil)
        #expect((photo.value(forKey: "livePhotoImageData") as? Data) == nil)
        #expect((photo.value(forKey: "livePhotoVideoData") as? Data) == nil)
    }

    @MainActor
    @Test(
        "PhotoStorageService re-downloads still image after cache eviction",
        .enabled(if: runsCloudKitIntegrationTests, "Set RUN_CLOUDKIT_TESTS=1 with an authenticated iCloud simulator")
    )
    func photoStorageRedownloadsStillImageAfterCacheEviction() async throws {
        let context = PersistenceController(inMemory: true).container.viewContext
        let image = makeImage(size: CGSize(width: 640, height: 480), color: .systemTeal)
        let imageData = try #require(image.jpegData(compressionQuality: 0.9))

        let objectID = try await PhotoStorageService.shared.saveImportedPhoto(
            imageData: imageData,
            context: context,
            enqueuesPendingUpload: false
        )
        let photo = try #require(context.existingObject(with: objectID) as? DailyPhoto)
        await PhotoUploadService.shared.processPendingUploadsForTesting()
        let assetName = try #require(photo.fullImageAssetName)

        let originalURL = try await CloudKitService.shared.loadAssetURL(named: assetName)
        #expect(FileManager.default.fileExists(atPath: originalURL.path))

        CloudKitService.shared.deleteAsset(named: assetName)
        #expect(FileManager.default.fileExists(atPath: originalURL.path) == false)

        let restoredImage = try await PhotoStorageService.shared.loadFullImage(from: photo)
        let restoredURL = try await CloudKitService.shared.loadAssetURL(named: assetName)
        defer { try? FileManager.default.removeItem(at: restoredURL) }

        #expect(FileManager.default.fileExists(atPath: restoredURL.path))
        #expect(restoredImage.cgImage != nil)
        #expect(restoredImage.size.width > 0)
        #expect(restoredImage.size.height > 0)
    }

    @MainActor
    @Test("PhotoStorageService returns paired Live Photo share URLs")
    func photoStoragePrepareLivePhotoShareURLs() async throws {
        let context = PersistenceController(inMemory: true).container.viewContext
        let photo = DailyPhoto(context: context)
        photo.id = UUID()

        let imageName = "\(UUID().uuidString).heic"
        _ = try CloudKitService.shared.stageAssetData(Data([0xAA]), named: imageName)
        let videoURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        try Data([0xBB]).write(to: videoURL)
        let videoName = "\(UUID().uuidString).mov"
        _ = try CloudKitService.shared.stageAssetFile(from: videoURL, named: videoName)
        defer {
            try? FileManager.default.removeItem(at: videoURL)
            CloudKitService.shared.deleteAsset(named: imageName)
            CloudKitService.shared.deleteAsset(named: videoName)
        }

        photo.livePhotoImageAssetName = imageName
        photo.livePhotoVideoAssetName = videoName

        let urls = try await PhotoStorageService.shared.prepareLivePhotoShareItemURLs(for: photo)
        #expect(urls.count == 2)
        #expect(urls.contains(where: { $0.lastPathComponent == imageName }))
        #expect(urls.contains(where: { $0.lastPathComponent == videoName }))
    }

    @MainActor
    @Test(
        "PhotoStorageService re-downloads Live Photo resources after cache eviction",
        .enabled(if: runsCloudKitIntegrationTests, "Set RUN_CLOUDKIT_TESTS=1 with an authenticated iCloud simulator")
    )
    func photoStorageRedownloadsLivePhotoResourcesAfterCacheEviction() async throws {
        let context = PersistenceController(inMemory: true).container.viewContext
        let image = makeImage(size: CGSize(width: 640, height: 480), color: .systemPink)
        let imageData = try #require(image.jpegData(compressionQuality: 0.9))

        let videoURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        try Data([0x01, 0x02, 0x03, 0x04]).write(to: videoURL)
        defer { try? FileManager.default.removeItem(at: videoURL) }

        let objectID = try await PhotoStorageService.shared.saveImportedLivePhoto(
            imageData: imageData,
            videoURL: videoURL,
            context: context
        )
        let photo = try #require(context.existingObject(with: objectID) as? DailyPhoto)
        await PhotoUploadService.shared.processPendingUploadsForTesting()

        let imageAssetName = try #require(photo.livePhotoImageAssetName)
        let videoAssetName = try #require(photo.livePhotoVideoAssetName)
        let cachedImageURL = try await CloudKitService.shared.loadAssetURL(named: imageAssetName)
        let cachedVideoURL = try await CloudKitService.shared.loadAssetURL(named: videoAssetName)

        CloudKitService.shared.deleteAsset(named: imageAssetName)
        CloudKitService.shared.deleteAsset(named: videoAssetName)
        #expect(FileManager.default.fileExists(atPath: cachedImageURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: cachedVideoURL.path) == false)

        let resources = try await PhotoStorageService.shared.loadLivePhotoResources(from: photo)
        defer {
            try? FileManager.default.removeItem(at: resources.imageURL)
            try? FileManager.default.removeItem(at: resources.videoURL)
        }

        #expect(FileManager.default.fileExists(atPath: resources.imageURL.path))
        #expect(FileManager.default.fileExists(atPath: resources.videoURL.path))
        let restoredVideoData = try Data(contentsOf: resources.videoURL)
        #expect(restoredVideoData == Data([0x01, 0x02, 0x03, 0x04]))
    }

    @MainActor
    @Test("PhotoStorageService delete removes metadata and staged assets")
    func photoStorageDeleteRemovesMetadataAndRemoteAssets() async throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let image = makeImage(size: CGSize(width: 640, height: 480), color: .systemIndigo)
        let imageData = try #require(image.jpegData(compressionQuality: 0.9))

        let objectID = try await PhotoStorageService.shared.saveImportedPhoto(
            imageData: imageData,
            context: context,
            enqueuesPendingUpload: false
        )
        let photo = try #require(context.existingObject(with: objectID) as? DailyPhoto)
        let assetName = try #require(photo.fullImageAssetName)
        _ = try #require(CloudKitService.shared.stagedAssetURL(named: assetName))

        try await PhotoStorageService.shared.deletePhoto(objectID, context: context)

        let request = DailyPhoto.fetchRequest()
        let storedCount = try context.count(for: request)
        #expect(storedCount == 0)
        #expect(CloudKitService.shared.stagedAssetURL(named: assetName) == nil)
    }

    @MainActor
    @Test("PhotoStorageService throws if no still asset exists")
    func photoStorageStillShareURLThrowsWithoutAsset() async {
        let context = PersistenceController(inMemory: true).container.viewContext
        let photo = DailyPhoto(context: context)
        photo.id = UUID()
        photo.fullImageAssetName = nil

        do {
            _ = try await PhotoStorageService.shared.prepareStillPhotoShareURL(for: photo)
            Issue.record("Expected PhotoStorageError.noImageAsset")
        } catch let error as PhotoStorageError {
            switch error {
            case .noImageAsset:
                break
            default:
                Issue.record("Expected PhotoStorageError.noImageAsset but got \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @MainActor
    @Test("PhotoStorageService batch delete removes selected records together")
    func photoStorageBatchDeleteRemovesSelectedRecordsTogether() async throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let image = makeImage(size: CGSize(width: 320, height: 320), color: .systemTeal)
        let imageData = try #require(image.jpegData(compressionQuality: 0.9))

        let firstID = try await PhotoStorageService.shared.saveImportedPhoto(
            imageData: imageData,
            context: context,
            enqueuesPendingUpload: false
        )
        let secondID = try await PhotoStorageService.shared.saveImportedPhoto(
            imageData: imageData,
            context: context,
            enqueuesPendingUpload: false
        )
        let thirdID = try await PhotoStorageService.shared.saveImportedPhoto(
            imageData: imageData,
            context: context,
            enqueuesPendingUpload: false
        )

        let deletedCount = try await PhotoStorageService.shared.deletePhotos(
            [firstID, secondID],
            context: context,
            deletesAssetsInBackground: true
        )

        #expect(deletedCount == 2)
        #expect(try context.existingObject(with: thirdID) is DailyPhoto)

        let request = DailyPhoto.fetchRequest()
        let remainingPhotos = try context.fetch(request)
        #expect(remainingPhotos.map(\.objectID) == [thirdID])
    }

    @MainActor
    private func makeImage(size: CGSize, color: UIColor) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}
