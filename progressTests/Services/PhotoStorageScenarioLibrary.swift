import CloudKit
import CoreData
import CryptoKit
import Foundation
import Testing
import UIKit
@testable import progress

/// Every file, preference, upload owner, and optional CloudKit zone belongs to
/// this fixture. No helper uses the application's real library or upload queue.
@MainActor
final class PhotoStorageScenarioLibrary {
    @MainActor final class Network {
        var data: [String: Data] = [:]
        var urls: [String: URL] = [:]
        var records: Set<CKRecord.ID> = []
        var downloads: [String] = []
        var uploads: [String] = []
        var deleted: Set<CKRecord.ID> = []
        var failingDownloads: Set<String> = []
        var metadataFailure: (any Error)?
        var uploadFailure: (any Error)?
        var accountFailure: (any Error)?
        var account = "storage-test-account"
        var deletionBatches = 0
        var failDeletionAtBatch: Int?
        var ignoresDeletion = false
        var afterDownload: (@MainActor (String) -> Void)?

        func metadata(_ name: String) throws -> PhotoAssetMetadata {
            if let metadataFailure { throw metadataFailure }
            guard let bytes = data[name] else { throw CloudKitError.assetNotFound }
            return PhotoAssetMetadata(byteCount: Int64(bytes.count), checksum: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        }
    }

    let root: URL
    let modeURL: URL
    private(set) var modeStore: PhotoStorageModeStore
    private(set) var persistence: PersistenceController
    private(set) var cloud: CloudKitService
    let network: Network
    let defaults: UserDefaults
    let defaultsName: String
    let photoID: UUID
    let names: Set<String>
    let zoneID: CKRecordZone.ID?
    private let cloudLibraryLoader: (@MainActor (NSPersistentContainer) async throws -> Void)?
    private let mirrorsCloud: Bool
    var capacity: Int64? = 10_000_000_000
    lazy var remoteAssetDeletions = RemoteAssetDeletionService(
        storageURL: root.appendingPathComponent("remote-deletions.json"),
        cloudOperationsAvailable: { [weak self] in
            await self?.modeStore.mode.allowsCloudWrites ?? false
        }, deleteRemoteAssets: { [weak self] names in
            await MainActor.run {
                guard let self else { return [:] }
                let ids = Set(names.map { CKRecord.ID(recordName: $0) })
                self.network.deleted.formUnion(ids)
                self.network.records.subtract(ids)
                return Dictionary(uniqueKeysWithValues: names.map { ($0, .success) })
            }
        }
    )

    init(zoneID: CKRecordZone.ID? = nil, empty: Bool = false, mirrorsCloud: Bool = false,
         cloudLibraryLoader: (@MainActor (NSPersistentContainer) async throws -> Void)? = nil) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("StorageScenarios-\(UUID())", isDirectory: true)
        modeURL = root.appendingPathComponent("preference/mode.json")
        modeStore = PhotoStorageModeStore(storageURL: modeURL)
        defaultsName = "StorageScenarios.\(UUID())"
        defaults = try #require(UserDefaults(suiteName: defaultsName))
        network = Network()
        photoID = UUID()
        names = empty ? [] : ["\(photoID)-still.png", "\(photoID)-live.png", "\(photoID)-live.mov"]
        self.zoneID = zoneID
        self.cloudLibraryLoader = cloudLibraryLoader
        self.mirrorsCloud = mirrorsCloud
        try FileManager.default.createDirectory(at: root.appendingPathComponent("library"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("server"), withIntermediateDirectories: true)
        if mirrorsCloud { try modeStore.set(.local) }
        persistence = PersistenceController(storageModeStore: modeStore, storeURL: root.appendingPathComponent("library/photos.sqlite"), cloudEnabled: mirrorsCloud,
                                            cloudLibraryLoader: cloudLibraryLoader)
        cloud = Self.makeCloud(root: root, state: network, defaults: defaults, modeStore: modeStore, zoneID: zoneID)
        try await Self.waitUntilLoaded(persistence)
        if mirrorsCloud { try modeStore.set(.iCloud) }
        if !empty {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512)).image { context in
                UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
            }
            let imageData = try #require(image.pngData())
            for name in names {
                let bytes = name.hasSuffix(".mov") ? Data("Synthetic movie resource \(photoID)".utf8) : imageData
                let url = root.appendingPathComponent("server").appendingPathComponent(name)
                try bytes.write(to: url, options: .atomic)
                network.data[name] = bytes
                network.urls[name] = url
                _ = try cloud.stageAssetData(bytes, named: name)
            }
            let photo = DailyPhoto(context: persistence.container.viewContext)
            photo.id = photoID
            photo.fullImageAssetName = "\(photoID)-still.png"
            photo.livePhotoImageAssetName = "\(photoID)-live.png"
            photo.livePhotoVideoAssetName = "\(photoID)-live.mov"
            photo.captureDate = Date(timeIntervalSince1970: 1_700_000_000)
            photo.createdAt = photo.captureDate
            photo.modifiedAt = photo.captureDate
            photo.thumbnailData = imageData
            photo.locationName = "Synthetic storage-test location"
            photo.latitude = 48.1; photo.longitude = 11.6
            photo.isHearted = true
            try persistence.container.viewContext.save()
        }
    }

    private static func makeCloud(root: URL, state: Network, defaults: UserDefaults, modeStore: PhotoStorageModeStore, zoneID: CKRecordZone.ID?) -> CloudKitService {
        let downloader: @MainActor @Sendable (String) async throws -> URL = { name in
            state.downloads.append(name)
            if state.failingDownloads.contains(name) { throw CKError(.networkFailure) }
            guard let url = state.urls[name] else { throw CloudKitError.assetNotFound }
            state.afterDownload?(name)
            return url
        }
        let metadata: @MainActor @Sendable (String) async throws -> PhotoAssetMetadata = { name in try state.metadata(name) }
        let uploader: @MainActor @Sendable (String, UUID, PhotoAssetRole) async throws -> Void = { name, _, _ in
            if let failure = state.uploadFailure { throw failure }
            state.uploads.append(name)
            state.records.insert(CKRecord.ID(recordName: name))
        }
        let existence: @MainActor @Sendable (String) async throws -> Bool = { name in state.records.contains(CKRecord.ID(recordName: name)) }
        return CloudKitService(stagingDirectoryURL: root.appendingPathComponent("staging"),
                                temporaryReadableAssetsDirectoryURL: root.appendingPathComponent("readable"), legacyAssetDirectoryURLs: [],
                                assetURLLoader: zoneID == nil ? downloader : nil, assetUploader: zoneID == nil ? uploader : nil, remoteAssetExistenceChecker: zoneID == nil ? existence : nil,
                                offlineSettingsDefaults: defaults, assetMetadataLoader: zoneID == nil ? metadata : nil, storageModeStore: modeStore,
                                recordZoneID: zoneID ?? CKRecordZone.default().zoneID)
    }

    /// Reconstructs the disk store, preference, cache inventory, and upload journal.
    /// No in-memory migration state is reused, as after process termination.
    func reopen() async throws {
        persistence.container.viewContext.reset()
        for store in persistence.container.persistentStoreCoordinator.persistentStores { try persistence.container.persistentStoreCoordinator.remove(store) }
        modeStore = PhotoStorageModeStore(storageURL: modeURL)
        persistence = PersistenceController(storageModeStore: modeStore, storeURL: root.appendingPathComponent("library/photos.sqlite"), cloudEnabled: mirrorsCloud,
                                            cloudLibraryLoader: cloudLibraryLoader)
        cloud = Self.makeCloud(root: root, state: network, defaults: defaults, modeStore: modeStore, zoneID: zoneID)
        try await Self.waitUntilLoaded(persistence)
    }

    func copies(pageSize: Int? = nil) -> PhotoCloudCopyService {
        if let zoneID { return PhotoCloudCopyService(recordZoneID: zoneID, recordPageSize: pageSize) }
        let state = network
        return PhotoCloudCopyService(accountIDProvider: {
            if let failure = state.accountFailure { throw failure }; return state.account
        }, recordIDsProvider: { state.records }, deleteRecords: { ids in
            state.deletionBatches += 1
            if state.failDeletionAtBatch == state.deletionBatches { throw CKError(.networkFailure) }
            if !state.ignoresDeletion { state.deleted.formUnion(ids); state.records.subtract(ids) }
        }, existingRecords: { Set($0).intersection(state.records) })
    }

    func coordinator(capacityProvider: (@Sendable () async -> Int64?)? = nil) -> PhotoStorageCoordinator {
        PhotoStorageCoordinator(cloudKitService: cloud, persistenceController: persistence, cloudCopyService: copies(),
                                remoteAssetDeletionService: remoteAssetDeletions,
                                capacityProvider: capacityProvider ?? { [weak self] in await self?.capacity },
                                suspendServices: {}, resumeServices: {}, validateMigrationReadiness: { _ in })
    }

    func uploader() -> PhotoUploadService {
        let store = modeStore
        return PhotoUploadService(cloudKitService: cloud, context: persistence.makeBackgroundContext(), cloudOperationsAvailable: { store.mode.allowsCloudWrites })
    }

    func uploadOriginals() async throws {
        for name in names.sorted() {
            let role: PhotoAssetRole = name.hasSuffix(".mov") ? .livePhotoVideo : name.contains("-live.") ? .livePhotoImage : .still
            try await cloud.uploadStagedAsset(named: name, photoID: photoID, role: role, retainsStagedOriginal: true)
        }
    }

    func makeRemoteOnly() async throws {
        for name in names { cloud.removeStagedAsset(named: name); cloud.discardTemporaryReadableAsset(named: name) }
        try await cloud.offlineStore.removeUnselected(keeping: [])
    }

    func assertLocalOriginals() async throws {
        for name in names {
            let url = try #require(try await cloud.offlineStore.assetURL(named: name))
            #expect(try Data(contentsOf: url) == network.data[name])
            try await cloud.offlineStore.verifyOriginal(named: name)
        }
    }

    func cleanup() {
        persistence.container.viewContext.reset()
        for store in persistence.container.persistentStoreCoordinator.persistentStores { try? persistence.container.persistentStoreCoordinator.remove(store) }
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: root)
    }

    static func waitUntilLoaded(_ persistence: PersistenceController) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !persistence.isLoaded, ContinuousClock.now < deadline {
            if case .failed(let message) = persistence.loadState { throw PhotoStorageMigrationError.attention(message) }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(persistence.isLoaded)
    }
}
