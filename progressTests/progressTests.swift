import CoreData
import Foundation
import Testing
import UIKit
@testable import progress

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

    @Test("Reminder times are clamped, sorted, deduplicated, and capped")
    func dailyReminderLoadSanitizesPersistedData() throws {
        let key = "dailyPhotoReminderTimes"
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let persisted: [DailyReminderTime] = [
            .init(id: UUID(), hour: 10, minute: 15),
            .init(id: UUID(), hour: 10, minute: 15),
            .init(id: UUID(), hour: 26, minute: 80),
            .init(id: UUID(), hour: -1, minute: -2),
            .init(id: UUID(), hour: 9, minute: 30)
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
        #expect(!DailyReminderNotificationService.shared.isDailyReminderNotification(userInfo: wrongDestination))
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
    @Test("CloudKitService saves image bytes and resolves asset URL")
    func cloudKitSaveImageDataAndLoadURL() async throws {
        let image = makeImage(size: CGSize(width: 320, height: 320), color: .green)
        let imageData = try #require(image.jpegData(compressionQuality: 0.9))

        let assetName = try await CloudKitService.shared.saveImageDataAsset(imageData, fileExtension: "jpg")
        let assetURL = try CloudKitService.shared.loadAssetURL(named: assetName)
        defer { try? FileManager.default.removeItem(at: assetURL) }

        #expect(FileManager.default.fileExists(atPath: assetURL.path))
        let loadedData = try Data(contentsOf: assetURL)
        #expect(loadedData == imageData)
    }

    @Test("CloudKitService throws for unknown asset names")
    func cloudKitThrowsForMissingAssetURL() {
        do {
            _ = try CloudKitService.shared.loadAssetURL(named: "\(UUID().uuidString).missing")
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

        let photo = try await PhotoStorageService.shared.saveImportedPhoto(imageData: imageData, context: context)
        let assetName = try #require(photo.fullImageAssetName)
        let assetURL = try CloudKitService.shared.loadAssetURL(named: assetName)
        defer { try? FileManager.default.removeItem(at: assetURL) }

        #expect(photo.id != nil)
        #expect(photo.captureDate != nil)
        #expect(photo.thumbnailData != nil)
        #expect(FileManager.default.fileExists(atPath: assetURL.path))
    }

    @MainActor
    @Test("PhotoStorageService returns still photo share URL")
    func photoStoragePrepareStillShareURL() throws {
        let context = PersistenceController(inMemory: true).container.viewContext
        let photo = DailyPhoto(context: context)
        photo.id = UUID()

        let fileName = "\(UUID().uuidString).jpg"
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try Data([0x01, 0x02, 0x03]).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        photo.fullImageAssetName = fileName
        let shareURL = try PhotoStorageService.shared.prepareStillPhotoShareURL(for: photo)
        #expect(shareURL.lastPathComponent == fileName)
    }

    @MainActor
    @Test("PhotoStorageService returns paired Live Photo share URLs")
    func photoStoragePrepareLivePhotoShareURLs() throws {
        let context = PersistenceController(inMemory: true).container.viewContext
        let photo = DailyPhoto(context: context)
        photo.id = UUID()

        let imageName = "\(UUID().uuidString).heic"
        let videoName = "\(UUID().uuidString).mov"
        let imageURL = FileManager.default.temporaryDirectory.appendingPathComponent(imageName)
        let videoURL = FileManager.default.temporaryDirectory.appendingPathComponent(videoName)
        try Data([0xAA]).write(to: imageURL)
        try Data([0xBB]).write(to: videoURL)
        defer {
            try? FileManager.default.removeItem(at: imageURL)
            try? FileManager.default.removeItem(at: videoURL)
        }

        photo.livePhotoImageAssetName = imageName
        photo.livePhotoVideoAssetName = videoName

        let urls = try PhotoStorageService.shared.prepareLivePhotoShareItemURLs(for: photo)
        #expect(urls.count == 2)
        #expect(urls.contains(where: { $0.lastPathComponent == imageName }))
        #expect(urls.contains(where: { $0.lastPathComponent == videoName }))
    }

    @MainActor
    @Test("PhotoStorageService throws if no still asset exists")
    func photoStorageStillShareURLThrowsWithoutAsset() {
        let context = PersistenceController(inMemory: true).container.viewContext
        let photo = DailyPhoto(context: context)
        photo.id = UUID()
        photo.fullImageAssetName = nil

        do {
            _ = try PhotoStorageService.shared.prepareStillPhotoShareURL(for: photo)
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
    private func makeImage(size: CGSize, color: UIColor) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}
