import SwiftUI

struct StorageDebugView: View {
    @State private var snapshot: AppStorageDebugSnapshot?
    @State private var isLoading = false
    @State private var isPurgingOtherCaches = false
    @State private var isClearingLegacyBlobs = false
    @State private var actionMessage: String?

    var body: some View {
        Form {
            if let snapshot {
                Section("Summary") {
                    storageRow(
                        title: "App Container",
                        detail: "Approximate storage counted from Documents, Library, and tmp.",
                        allocatedBytes: snapshot.containerAllocatedBytes,
                        logicalBytes: snapshot.containerLogicalBytes,
                        fileCount: nil
                    )

                    if let photoCount = snapshot.photoCount {
                        LabeledContent("Stored Photos", value: "\(photoCount)")
                    }

                    LabeledContent(
                        "Full-Resolution Limit",
                        value: PhotoAssetCacheSettings.formattedByteCount(PhotoAssetCacheSettings.currentLimitBytes)
                    )

                    LabeledContent("Updated", value: snapshot.generatedAt.formatted(date: .omitted, time: .standard))
                }

                if let actionMessage {
                    Section {
                        Text(actionMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Actions") {
                    Button(role: .destructive) {
                        purgeOtherCaches()
                    } label: {
                        if isPurgingOtherCaches {
                            Label("Purging Other Caches…", systemImage: "trash")
                        } else {
                            Label("Purge Other Caches", systemImage: "trash")
                        }
                    }
                    .disabled(isLoading || isPurgingOtherCaches || isClearingLegacyBlobs)

                    Button {
                        clearLegacyBlobs()
                    } label: {
                        if isClearingLegacyBlobs {
                            Label("Clearing Old Photo Blobs…", systemImage: "externaldrive.badge.xmark")
                        } else {
                            Label("Clear Old Full-Resolution Blobs", systemImage: "externaldrive.badge.xmark")
                        }
                    }
                    .disabled(
                        isLoading ||
                        isPurgingOtherCaches ||
                        isClearingLegacyBlobs ||
                        (snapshot.legacyBlobPhotoCount ?? 0) == 0
                    )

                    if let legacyBlobPhotoCount = snapshot.legacyBlobPhotoCount {
                        Text("\(legacyBlobPhotoCount) photo\(legacyBlobPhotoCount == 1 ? "" : "s") still have old binary image data in Core Data.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Known Storage") {
                    ForEach(snapshot.knownItems) { item in
                        StorageDebugItemRow(item: item)
                    }
                }

                if let stats = snapshot.coreDataSQLiteStats {
                    Section("SQLite Contents") {
                        byteRow(
                            title: "Pages Used",
                            bytes: stats.usedPageBytes,
                            detail: "\(PhotoAssetCacheSettings.formattedByteCount(stats.totalBytes)) total in progress.sqlite"
                        )
                        byteRow(
                            title: "Free Inside DB",
                            bytes: stats.freeBytes,
                            detail: "Old data may be gone, but SQLite can keep empty pages until the store is compacted."
                        )
                        byteRow(
                            title: "Thumbnail Blobs",
                            bytes: stats.thumbnailBytes,
                            detail: "Kept forever by app design."
                        )
                        byteRow(
                            title: "Old Full-Resolution Blobs",
                            bytes: stats.fullImageBytes,
                            detail: "Should become 0 after old full-resolution data is cleared."
                        )
                        byteRow(
                            title: "Old Live Photo Image Blobs",
                            bytes: stats.livePhotoImageBytes,
                            detail: "Legacy image data from Live Photos."
                        )
                        byteRow(
                            title: "Old Live Photo Video Blobs",
                            bytes: stats.livePhotoVideoBytes,
                            detail: "Legacy video data from Live Photos."
                        )
                        byteRow(
                            title: "Known Photo Blob Total",
                            bytes: stats.knownBlobBytes,
                            detail: "Thumbnail blobs plus legacy full-resolution blobs counted in DailyPhoto."
                        )
                        LabeledContent("DailyPhoto Rows", value: "\(stats.dailyPhotoRowCount)")
                    }
                }

                if !snapshot.largestOtherCacheItems.isEmpty {
                    Section("Biggest Other Caches") {
                        ForEach(snapshot.largestOtherCacheItems) { item in
                            StorageDebugItemRow(item: item)
                        }
                    }
                }

                if !snapshot.coreDataItems.isEmpty {
                    Section("Core Data Pieces") {
                        ForEach(snapshot.coreDataItems) { item in
                            StorageDebugItemRow(item: item)
                        }
                    }
                }

                Section("Top Level") {
                    ForEach(snapshot.topLevelItems) { item in
                        StorageDebugItemRow(item: item)
                    }
                }

                if let coreDataStorePath = snapshot.coreDataStorePath {
                    Section("Core Data Store") {
                        Text(coreDataStorePath)
                            .font(.footnote)
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if isLoading {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Calculating storage…")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Storage Debug")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
        }
        .task {
            guard snapshot == nil else { return }
            await refreshSnapshot()
        }
        .refreshable {
            await refreshSnapshot()
        }
    }

    private func refresh() {
        Task {
            await refreshSnapshot()
        }
    }

    private func purgeOtherCaches() {
        Task { @MainActor in
            isPurgingOtherCaches = true
            actionMessage = nil

            do {
                try await AppStorageDebugService.shared.purgeOtherCaches()
                actionMessage = "Other caches purged."
                await refreshSnapshot()
            } catch {
                actionMessage = "Could not purge other caches."
            }

            isPurgingOtherCaches = false
        }
    }

    private func clearLegacyBlobs() {
        Task { @MainActor in
            isClearingLegacyBlobs = true
            actionMessage = nil

            do {
                let clearedCount = try await AppStorageDebugService.shared.clearLegacyFullResolutionBlobs()
                actionMessage = "Cleared old full-resolution blobs from \(clearedCount) photo\(clearedCount == 1 ? "" : "s")."
                await refreshSnapshot()
            } catch {
                actionMessage = "Could not clear old full-resolution blobs."
            }

            isClearingLegacyBlobs = false
        }
    }

    @MainActor
    private func refreshSnapshot() async {
        isLoading = true
        snapshot = await AppStorageDebugService.shared.snapshot()
        isLoading = false
    }

    @ViewBuilder
    private func storageRow(
        title: String,
        detail: String,
        allocatedBytes: Int,
        logicalBytes: Int,
        fileCount: Int?
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer()
                Text(PhotoAssetCacheSettings.formattedByteCount(allocatedBytes))
                    .foregroundStyle(.secondary)
            }

            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Text("Logical \(PhotoAssetCacheSettings.formattedByteCount(logicalBytes))")
                if let fileCount {
                    Text("\(fileCount) file\(fileCount == 1 ? "" : "s")")
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func byteRow(title: String, bytes: Int, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer()
                Text(PhotoAssetCacheSettings.formattedByteCount(bytes))
                    .foregroundStyle(.secondary)
            }

            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

private struct StorageDebugItemRow: View {
    let item: AppStorageDebugItem

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Text(item.detail)
                    .foregroundStyle(.secondary)

                Text(item.path)
                    .textSelection(.enabled)
                    .foregroundStyle(.tertiary)
            }
            .font(.footnote)
            .padding(.vertical, 4)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.title)
                    Spacer()
                    Text(PhotoAssetCacheSettings.formattedByteCount(item.allocatedBytes))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    Text("Logical \(PhotoAssetCacheSettings.formattedByteCount(item.logicalBytes))")
                    Text("\(item.fileCount) file\(item.fileCount == 1 ? "" : "s")")
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
        }
    }
}
