import CoreData
import Foundation
import SQLite3

nonisolated struct AppStorageDebugSnapshot: Sendable {
    let generatedAt: Date
    let containerAllocatedBytes: Int
    let containerLogicalBytes: Int
    let photoCount: Int?
    let coreDataStorePath: String?
    let knownItems: [AppStorageDebugItem]
    let topLevelItems: [AppStorageDebugItem]
    let largestOtherCacheItems: [AppStorageDebugItem]
    let coreDataItems: [AppStorageDebugItem]
    let coreDataSQLiteStats: CoreDataSQLiteStats?
    let legacyBlobPhotoCount: Int?
}

nonisolated struct AppStorageDebugItem: Identifiable, Sendable {
    let id: String
    let title: String
    let detail: String
    let path: String
    let allocatedBytes: Int
    let logicalBytes: Int
    let fileCount: Int
}

nonisolated struct CoreDataSQLiteStats: Sendable {
    let pageSize: Int
    let pageCount: Int
    let freePageCount: Int
    let dailyPhotoRowCount: Int
    let thumbnailBytes: Int
    let fullImageBytes: Int
    let livePhotoImageBytes: Int
    let livePhotoVideoBytes: Int

    var totalBytes: Int {
        pageSize * pageCount
    }

    var freeBytes: Int {
        pageSize * freePageCount
    }

    var usedPageBytes: Int {
        max(totalBytes - freeBytes, 0)
    }

    var knownBlobBytes: Int {
        thumbnailBytes + fullImageBytes + livePhotoImageBytes + livePhotoVideoBytes
    }

    var legacyFullResolutionBytes: Int {
        fullImageBytes + livePhotoImageBytes + livePhotoVideoBytes
    }
}

final class AppStorageDebugService {
    static let shared = AppStorageDebugService()

    private init() {}

    func snapshot() async -> AppStorageDebugSnapshot {
        let fileManager = FileManager.default
        let homeDirectory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let documentDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
        let libraryDirectory = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first
        let applicationSupportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
        let temporaryDirectory = fileManager.temporaryDirectory
        let assetDirectories = CloudKitService.shared.localAssetDirectoryURLs()
        let storeURL = PersistenceController.shared.container.persistentStoreCoordinator.persistentStores.first?.url
        let photoCount = countPhotos()
        let legacyBlobPhotoCount = countLegacyBlobPhotos()

        let snapshotData = await Task.detached(priority: .utility) {
            Self.makeSnapshotData(
                homeDirectory: homeDirectory,
                documentDirectory: documentDirectory,
                libraryDirectory: libraryDirectory,
                applicationSupportDirectory: applicationSupportDirectory,
                cachesDirectory: cachesDirectory,
                temporaryDirectory: temporaryDirectory,
                assetCacheDirectory: assetDirectories.cache,
                pendingUploadDirectory: assetDirectories.staging,
                storeURL: storeURL
            )
        }.value

        return AppStorageDebugSnapshot(
            generatedAt: Date(),
            containerAllocatedBytes: snapshotData.container.allocatedBytes,
            containerLogicalBytes: snapshotData.container.logicalBytes,
            photoCount: photoCount,
            coreDataStorePath: storeURL?.path(percentEncoded: false),
            knownItems: snapshotData.knownItems,
            topLevelItems: snapshotData.topLevelItems,
            largestOtherCacheItems: snapshotData.largestOtherCacheItems,
            coreDataItems: snapshotData.coreDataItems,
            coreDataSQLiteStats: snapshotData.coreDataSQLiteStats,
            legacyBlobPhotoCount: legacyBlobPhotoCount
        )
    }

    private func countPhotos() -> Int? {
        let request = DailyPhoto.fetchRequest()
        return try? PersistenceController.shared.container.viewContext.count(for: request)
    }

    private func countLegacyBlobPhotos() -> Int? {
        let request = DailyPhoto.fetchRequest()
        request.predicate = NSPredicate(
            format: "fullImageData != nil OR livePhotoImageData != nil OR livePhotoVideoData != nil"
        )
        return try? PersistenceController.shared.container.viewContext.count(for: request)
    }

    func purgeOtherCaches() async throws {
        let assetCacheDirectory = CloudKitService.shared.localAssetDirectoryURLs().cache
        let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first

        try await Task.detached(priority: .utility) {
            guard let cachesDirectory else { return }
            try Self.deleteContents(of: cachesDirectory, preserving: [assetCacheDirectory])
        }.value
    }

    func clearLegacyFullResolutionBlobs() async throws -> Int {
        let context = PersistenceController.shared.makeBackgroundContext()
        return try await context.perform {
            let request = DailyPhoto.fetchRequest()
            request.fetchBatchSize = 100
            request.predicate = NSPredicate(
                format: """
                (fullImageData != nil OR livePhotoImageData != nil OR livePhotoVideoData != nil)
                AND (fullImageAssetName != nil OR livePhotoImageAssetName != nil OR livePhotoVideoAssetName != nil)
                """
            )

            let photos = try context.fetch(request)
            guard !photos.isEmpty else { return 0 }

            for photo in photos {
                photo.setValue(nil, forKey: "fullImageData")
                photo.setValue(nil, forKey: "livePhotoImageData")
                photo.setValue(nil, forKey: "livePhotoVideoData")
            }

            try context.save()
            context.reset()
            return photos.count
        }
    }

    nonisolated private static func makeSnapshotData(
        homeDirectory: URL,
        documentDirectory: URL?,
        libraryDirectory: URL?,
        applicationSupportDirectory: URL?,
        cachesDirectory: URL?,
        temporaryDirectory: URL,
        assetCacheDirectory: URL,
        pendingUploadDirectory: URL,
        storeURL: URL?
    ) -> (
        container: DirectoryMeasurement,
        knownItems: [AppStorageDebugItem],
        topLevelItems: [AppStorageDebugItem],
        largestOtherCacheItems: [AppStorageDebugItem],
        coreDataItems: [AppStorageDebugItem],
        coreDataSQLiteStats: CoreDataSQLiteStats?
    ) {
        let containerMeasurement = measure(homeDirectory)
        let documentMeasurement = documentDirectory.map(measure)
        let libraryMeasurement = libraryDirectory.map(measure)
        let temporaryMeasurement = measure(temporaryDirectory)
        let applicationSupportMeasurement = applicationSupportDirectory.map(measure)
        let cachesMeasurement = cachesDirectory.map(measure)
        let assetCacheMeasurement = measure(assetCacheDirectory)
        let pendingUploadMeasurement = measure(pendingUploadDirectory)
        let coreDataMeasurement = storeURL.map(coreDataMeasurement)
        let coreDataItems = storeURL.map(coreDataItems) ?? []
        let coreDataSQLiteStats = storeURL.flatMap(sqliteStats)
        let largestOtherCacheItems = cachesDirectory.map {
            childItems(
                inside: $0,
                idPrefix: "other-cache",
                excluding: [assetCacheDirectory],
                limit: 15
            )
        } ?? []

        var knownItems: [AppStorageDebugItem] = []
        if let coreDataMeasurement, let storeURL {
            knownItems.append(
                item(
                    id: "core-data",
                    title: "Core Data",
                    detail: "SQLite store, WAL/SHM files, and external binary storage for metadata and thumbnails.",
                    url: storeURL,
                    measurement: coreDataMeasurement
                )
            )
        }

        knownItems.append(
            item(
                id: "full-resolution-cache",
                title: "Full-Resolution Cache",
                detail: "Local full-resolution photo copies controlled by the cache limit.",
                url: assetCacheDirectory,
                measurement: assetCacheMeasurement
            )
        )
        knownItems.append(
            item(
                id: "pending-uploads",
                title: "Pending Uploads",
                detail: "Original assets waiting for CloudKit upload; these are not part of the cache limit.",
                url: pendingUploadDirectory,
                measurement: pendingUploadMeasurement
            )
        )

        if let applicationSupportDirectory, let applicationSupportMeasurement {
            let knownApplicationSupportBytes = [
                coreDataMeasurement,
                pendingUploadMeasurement
            ].compactMap(\.self).reduce(0) { $0 + $1.allocatedBytes }
            let knownApplicationSupportLogicalBytes = [
                coreDataMeasurement,
                pendingUploadMeasurement
            ].compactMap(\.self).reduce(0) { $0 + $1.logicalBytes }
            knownItems.append(
                item(
                    id: "application-support-other",
                    title: "Other Application Support",
                    detail: "Application Support minus Core Data and pending uploads.",
                    url: applicationSupportDirectory,
                    allocatedBytes: max(applicationSupportMeasurement.allocatedBytes - knownApplicationSupportBytes, 0),
                    logicalBytes: max(applicationSupportMeasurement.logicalBytes - knownApplicationSupportLogicalBytes, 0),
                    fileCount: max(applicationSupportMeasurement.fileCount - (coreDataMeasurement?.fileCount ?? 0) - pendingUploadMeasurement.fileCount, 0)
                )
            )
        }

        if let cachesDirectory, let cachesMeasurement {
            knownItems.append(
                item(
                    id: "caches-other",
                    title: "Other Caches",
                    detail: "Library/Caches minus the full-resolution photo cache.",
                    url: cachesDirectory,
                    allocatedBytes: max(cachesMeasurement.allocatedBytes - assetCacheMeasurement.allocatedBytes, 0),
                    logicalBytes: max(cachesMeasurement.logicalBytes - assetCacheMeasurement.logicalBytes, 0),
                    fileCount: max(cachesMeasurement.fileCount - assetCacheMeasurement.fileCount, 0)
                )
            )
        }

        knownItems.append(
            item(
                id: "temporary-files",
                title: "Temporary Files",
                detail: "Files in tmp that iOS may purge outside the app lifecycle.",
                url: temporaryDirectory,
                measurement: temporaryMeasurement
            )
        )

        let topLevelItems = [
            documentDirectory.flatMap { url in
                documentMeasurement.map {
                    item(id: "documents", title: "Documents", detail: "Top-level Documents directory.", url: url, measurement: $0)
                }
            },
            libraryDirectory.flatMap { url in
                libraryMeasurement.map {
                    item(id: "library", title: "Library", detail: "Application Support, Caches, Preferences, and Core Data files.", url: url, measurement: $0)
                }
            },
            item(id: "tmp", title: "tmp", detail: "Top-level temporary directory.", url: temporaryDirectory, measurement: temporaryMeasurement)
        ].compactMap(\.self)

        return (
            container: containerMeasurement,
            knownItems: knownItems.sorted { $0.allocatedBytes > $1.allocatedBytes },
            topLevelItems: topLevelItems.sorted { $0.allocatedBytes > $1.allocatedBytes },
            largestOtherCacheItems: largestOtherCacheItems,
            coreDataItems: coreDataItems,
            coreDataSQLiteStats: coreDataSQLiteStats
        )
    }

    nonisolated private static func sqliteStats(for storeURL: URL) -> CoreDataSQLiteStats? {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(storeURL.path, &database, flags, nil) == SQLITE_OK, let database else {
            return nil
        }
        defer { sqlite3_close(database) }

        guard
            let pageSize = queryPragmaInt(database, name: "page_size"),
            let pageCount = queryPragmaInt(database, name: "page_count"),
            let freePageCount = queryPragmaInt(database, name: "freelist_count"),
            let blobStats = queryDailyPhotoBlobStats(database)
        else {
            return nil
        }

        return CoreDataSQLiteStats(
            pageSize: pageSize,
            pageCount: pageCount,
            freePageCount: freePageCount,
            dailyPhotoRowCount: blobStats.rowCount,
            thumbnailBytes: blobStats.thumbnailBytes,
            fullImageBytes: blobStats.fullImageBytes,
            livePhotoImageBytes: blobStats.livePhotoImageBytes,
            livePhotoVideoBytes: blobStats.livePhotoVideoBytes
        )
    }

    nonisolated private static func queryPragmaInt(_ database: OpaquePointer, name: String) -> Int? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA \(name)", -1, &statement, nil) == SQLITE_OK, let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    nonisolated private static func queryDailyPhotoBlobStats(_ database: OpaquePointer) -> (
        rowCount: Int,
        thumbnailBytes: Int,
        fullImageBytes: Int,
        livePhotoImageBytes: Int,
        livePhotoVideoBytes: Int
    )? {
        let sql = """
        SELECT
            COUNT(*),
            COALESCE(SUM(LENGTH(ZTHUMBNAILDATA)), 0),
            COALESCE(SUM(LENGTH(ZFULLIMAGEDATA)), 0),
            COALESCE(SUM(LENGTH(ZLIVEPHOTOIMAGEDATA)), 0),
            COALESCE(SUM(LENGTH(ZLIVEPHOTOVIDEODATA)), 0)
        FROM ZDAILYPHOTO
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return (
            rowCount: Int(sqlite3_column_int64(statement, 0)),
            thumbnailBytes: Int(sqlite3_column_int64(statement, 1)),
            fullImageBytes: Int(sqlite3_column_int64(statement, 2)),
            livePhotoImageBytes: Int(sqlite3_column_int64(statement, 3)),
            livePhotoVideoBytes: Int(sqlite3_column_int64(statement, 4))
        )
    }

    nonisolated private static func coreDataMeasurement(for storeURL: URL) -> DirectoryMeasurement {
        let fileManager = FileManager.default
        let storeDirectory = storeURL.deletingLastPathComponent()
        let storeFileName = storeURL.lastPathComponent
        let candidateURLs = ((try? fileManager.contentsOfDirectory(
            at: storeDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []).filter { url in
            let fileName = url.lastPathComponent
            return fileName == storeFileName ||
                fileName.hasPrefix("\(storeFileName)-") ||
                fileName == "\(storeFileName)_SUPPORT"
        }

        return candidateURLs.reduce(DirectoryMeasurement.empty) { partialResult, url in
            partialResult + measure(url)
        }
    }

    nonisolated private static func coreDataItems(for storeURL: URL) -> [AppStorageDebugItem] {
        let fileManager = FileManager.default
        let storeDirectory = storeURL.deletingLastPathComponent()
        let storeFileName = storeURL.lastPathComponent
        let candidateURLs = ((try? fileManager.contentsOfDirectory(
            at: storeDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []).filter { url in
            let fileName = url.lastPathComponent
            return fileName == storeFileName ||
                fileName.hasPrefix("\(storeFileName)-") ||
                fileName == "\(storeFileName)_SUPPORT"
        }

        return candidateURLs.map { url in
            item(
                id: "core-data-\(url.lastPathComponent)",
                title: url.lastPathComponent,
                detail: "Core Data store component.",
                url: url,
                measurement: measure(url)
            )
        }
        .sorted { $0.allocatedBytes > $1.allocatedBytes }
    }

    nonisolated private static func childItems(
        inside directoryURL: URL,
        idPrefix: String,
        excluding excludedURLs: [URL],
        limit: Int
    ) -> [AppStorageDebugItem] {
        let excludedPaths = Set(excludedURLs.map { $0.standardizedFileURL.path })
        let children = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return children
            .filter { !excludedPaths.contains($0.standardizedFileURL.path) }
            .map { url in
                item(
                    id: "\(idPrefix)-\(url.lastPathComponent)",
                    title: url.lastPathComponent,
                    detail: "Direct child of \(directoryURL.lastPathComponent).",
                    url: url,
                    measurement: measure(url)
                )
            }
            .sorted { $0.allocatedBytes > $1.allocatedBytes }
            .prefix(limit)
            .map(\.self)
    }

    nonisolated private static func item(
        id: String,
        title: String,
        detail: String,
        url: URL,
        measurement: DirectoryMeasurement
    ) -> AppStorageDebugItem {
        item(
            id: id,
            title: title,
            detail: detail,
            url: url,
            allocatedBytes: measurement.allocatedBytes,
            logicalBytes: measurement.logicalBytes,
            fileCount: measurement.fileCount
        )
    }

    nonisolated private static func item(
        id: String,
        title: String,
        detail: String,
        url: URL,
        allocatedBytes: Int,
        logicalBytes: Int,
        fileCount: Int
    ) -> AppStorageDebugItem {
        AppStorageDebugItem(
            id: id,
            title: title,
            detail: detail,
            path: url.path(percentEncoded: false),
            allocatedBytes: allocatedBytes,
            logicalBytes: logicalBytes,
            fileCount: fileCount
        )
    }

    nonisolated private static func measure(_ url: URL) -> DirectoryMeasurement {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .empty
        }

        if !isDirectory.boolValue {
            return measurement(for: url)
        }

        guard let fileURLs = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return .empty
        }

        var measurement = DirectoryMeasurement.empty
        for case let fileURL as URL in fileURLs {
            measurement += self.measurement(for: fileURL)
        }
        return measurement
    }

    nonisolated private static func measurement(for fileURL: URL) -> DirectoryMeasurement {
        guard
            let values = try? fileURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .totalFileAllocatedSizeKey,
                .fileAllocatedSizeKey,
                .fileSizeKey
            ]),
            values.isRegularFile == true
        else {
            return .empty
        }

        return DirectoryMeasurement(
            allocatedBytes: values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0,
            logicalBytes: values.fileSize ?? 0,
            fileCount: 1
        )
    }

    nonisolated private static func deleteContents(of directoryURL: URL, preserving preservedURLs: [URL]) throws {
        let preservedPaths = Set(preservedURLs.map { $0.standardizedFileURL.path })
        let children = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        for child in children where !preservedPaths.contains(child.standardizedFileURL.path) {
            try? FileManager.default.removeItem(at: child)
        }
    }
}

nonisolated private struct DirectoryMeasurement: Sendable {
    static let empty = DirectoryMeasurement(allocatedBytes: 0, logicalBytes: 0, fileCount: 0)

    var allocatedBytes: Int
    var logicalBytes: Int
    var fileCount: Int

    static func + (lhs: DirectoryMeasurement, rhs: DirectoryMeasurement) -> DirectoryMeasurement {
        DirectoryMeasurement(
            allocatedBytes: lhs.allocatedBytes + rhs.allocatedBytes,
            logicalBytes: lhs.logicalBytes + rhs.logicalBytes,
            fileCount: lhs.fileCount + rhs.fileCount
        )
    }

    static func += (lhs: inout DirectoryMeasurement, rhs: DirectoryMeasurement) {
        lhs = lhs + rhs
    }
}
