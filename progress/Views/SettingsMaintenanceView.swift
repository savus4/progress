import SwiftUI
import CoreData

struct SettingsMaintenanceView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @StateObject private var cloudSyncMonitor = CloudSyncMonitor.shared
    @State private var offlineCoordinator = PhotoOfflineCoordinator.shared
    @State private var storage = PhotoStorageCoordinator.shared
    @AppStorage(PhotoOfflineSettings.keepAllKey) private var keepAllPhotos = false
    @AppStorage(PhotoOfflineSettings.keepHeartedKey) private var keepHeartedPhotos = false
    @AppStorage(PhotoOfflineSettings.cellularKey) private var allowCellularDownloads = false
    @AppStorage(PhotoOfflineSettings.recentPhotosKey) private var keepRecentPhotos = false
    @AppStorage(PhotoOfflineSettings.recentLimitKey) private var recentPhotoLimitBytes = PhotoOfflineSettings.defaultLimitBytes

    @State private var localAssetStorageUsage = LocalPhotoAssetStorageUsage.empty
    @State private var isLoadingLocalAssetStorageUsage = false
    @State private var deleteRangeStartDate = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var deleteRangeEndDate = Date()
    @State private var deleteRangeMatchCount = 0
    @State private var isLoadingDeleteRangeMatchCount = false
    @State private var isDeletingPhotosInRange = false
    @State private var showingDeleteRangeConfirmation = false
    @State private var deleteRangeStatusMessage: String?
    @State private var totalPhotoCount = 0
    @State private var isLoadingTotalPhotoCount = false
    @State private var isDeletingAllPhotos = false
    @State private var showingDeleteAllConfirmation = false
    @State private var deleteAllStatusMessage: String?

    var body: some View {
        Form {
            if storage.isLocalOnly {
                Section {
                    NavigationLink("Photo Storage") { PhotoStorageSettingsView() }
                    Text("Local storage keeps every original on this device. Offline cache preferences apply when iCloud sync is enabled.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("Offline Photos") {
                Toggle("Keep All Photos on Device", isOn: $keepAllPhotos)
                    .accessibilityIdentifier("keepAllPhotosOnDeviceToggle")
                Toggle("Keep Hearted Photos on Device", isOn: $keepHeartedPhotos)
                    .disabled(keepAllPhotos)
                    .accessibilityIdentifier("keepHeartedPhotosOnDeviceToggle")
                Toggle("Keep Recently Opened Photos", isOn: $keepRecentPhotos)
                    .disabled(keepAllPhotos)
                    .accessibilityIdentifier("keepRecentPhotosOnDeviceToggle")
                if keepRecentPhotos {
                    NavigationLink {
                        PhotoStorageLimitView(limitBytes: $recentPhotoLimitBytes)
                    } label: {
                        LabeledContent("Storage Limit", value: ByteCountFormatter.string(fromByteCount: PhotoOfflineSettings.recentLimitBytes(), countStyle: .decimal))
                    }
                    .disabled(keepAllPhotos)
                    .accessibilityIdentifier("recentPhotoStorageLimitRow")
                    if !keepAllPhotos {
                        LabeledContent("Recent Photos", value: ByteCountFormatter.string(fromByteCount: offlineCoordinator.recentPhotoBytes, countStyle: .decimal))
                    }
                }

                if keepAllPhotos || keepHeartedPhotos || keepRecentPhotos {
                    LabeledContent("Available Offline", value: "\(offlineCoordinator.availablePhotoCount) of \(offlineCoordinator.selectedPhotoCount) photos")
                    LabeledContent("Offline Originals", value: ByteCountFormatter.string(fromByteCount: offlineCoordinator.offlineBytes, countStyle: .decimal))
                    LabeledContent("Still to Download", value: offlineCoordinator.remainingDownloadBytes.map {
                        ByteCountFormatter.string(fromByteCount: $0, countStyle: .decimal)
                    } ?? "Calculating…")
                    if offlineCoordinator.isDownloading { ProgressView().controlSize(.small) }
                    Text(offlineCoordinator.statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Retry Downloads") { offlineCoordinator.requestReconciliation(delay: .zero) }
                        .disabled(offlineCoordinator.isDownloading || !offlineCoordinator.hasMissingPhotos)
                    Button("Recheck Storage") {
                        offlineCoordinator.requestReconciliation(delay: .zero)
                        refreshLocalAssetStorageUsage()
                    }
                }

                Toggle("Allow Cellular Downloads", isOn: $allowCellularDownloads)
                    .accessibilityIdentifier("allowCellularOfflineDownloadsToggle")
            }
            .disabled(storage.isLocalOnly)

            Section("Storage") {
                PhotoStorageBarView(
                    usage: localAssetStorageUsage,
                    heartedBytes: offlineCoordinator.heartedPhotoBytes,
                    recentBytes: offlineCoordinator.recentPhotoBytes,
                    recentLimitBytes: keepRecentPhotos && !keepAllPhotos ? PhotoOfflineSettings.recentLimitBytes() : nil
                )
                if isLoadingLocalAssetStorageUsage { ProgressView().controlSize(.small) }

                Button {
                    refreshLocalAssetStorageUsage()
                } label: {
                    Label("Recalculate Storage", systemImage: "arrow.clockwise")
                }
                .disabled(isLoadingLocalAssetStorageUsage)

                NavigationLink {
                    StorageDebugView()
                } label: {
                    Label("Storage Debug", systemImage: "internaldrive")
                }
            }

            Section("Delete Photos") {
                DatePicker(
                    "From",
                    selection: deleteRangeStartBinding,
                    displayedComponents: .date
                )
                .disabled(isDeletingPhotosInRange)

                DatePicker(
                    "To",
                    selection: deleteRangeEndBinding,
                    in: deleteRangeStartDate...,
                    displayedComponents: .date
                )
                .disabled(isDeletingPhotosInRange)

                if isLoadingDeleteRangeMatchCount {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Counting matching photos…")
                            .foregroundStyle(.secondary)
                    }
                    .font(.footnote)
                } else {
                    Text(deleteRangeCountDescription)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Button("Delete Matching Photos", role: .destructive) {
                    showingDeleteRangeConfirmation = true
                }
                .disabled(storage.mode.isMigrating || deleteRangeMatchCount == 0 || isDeletingPhotosInRange || isLoadingDeleteRangeMatchCount)

                if let deleteRangeStatusMessage {
                    Text(deleteRangeStatusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Start Fresh") {
                if isLoadingTotalPhotoCount {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Counting all stored photos…")
                            .foregroundStyle(.secondary)
                    }
                    .font(.footnote)
                } else {
                    Text(totalPhotoCount == 0
                         ? "There are no stored photos to remove."
                         : "Delete all \(totalPhotoCount) stored photo\(totalPhotoCount == 1 ? "" : "s") and remove their local assets.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Button("Delete All Photos", role: .destructive) {
                    showingDeleteAllConfirmation = true
                }
                .disabled(storage.mode.isMigrating || totalPhotoCount == 0 || isDeletingAllPhotos || isLoadingTotalPhotoCount)

                if let deleteAllStatusMessage {
                    Text(deleteAllStatusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Storage Management")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: [keepAllPhotos, keepHeartedPhotos, allowCellularDownloads, keepRecentPhotos]) { _, _ in
            offlineCoordinator.preferencesDidChange()
        }
        .onChange(of: recentPhotoLimitBytes) { _, _ in offlineCoordinator.preferencesDidChange() }
        .onChange(of: offlineCoordinator.offlineBytes) { _, _ in refreshLocalAssetStorageUsage() }
        .onChange(of: [cloudSyncMonitor.pendingUploadCount, cloudSyncMonitor.uploadingAssetCount, cloudSyncMonitor.downloadingAssetCount]) { _, _ in refreshLocalAssetStorageUsage() }
        .task {
            offlineCoordinator.start()
            refreshLocalAssetStorageUsage()
            await configureDeleteRange()
            await refreshTotalPhotoCount()
        }
        .alert(
            deleteRangeConfirmationTitle,
            isPresented: $showingDeleteRangeConfirmation
        ) {
            Button(deleteRangeConfirmationButtonTitle, role: .destructive) {
                deletePhotosInSelectedRange()
            }
            .disabled(isDeletingPhotosInRange || deleteRangeMatchCount == 0)

            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteRangeConfirmationMessage)
        }
        .alert(
            "Delete all photos?",
            isPresented: $showingDeleteAllConfirmation
        ) {
            Button("Delete All Photos", role: .destructive) {
                deleteAllPhotos()
            }
            .disabled(isDeletingAllPhotos || totalPhotoCount == 0)

            Button("Cancel", role: .cancel) {}
        } message: {
            Text(cloudSyncMonitor.isICloudUnavailable
                 ? "This will permanently delete every photo from Work in Progress on this device. iCloud cleanup will resume automatically when iCloud is enabled."
                 : "This will permanently delete every photo from Work in Progress on this device and remove the matching records and stored assets from iCloud.")
        }
    }

    private var deleteRangeStartBinding: Binding<Date> {
        Binding(
            get: { deleteRangeStartDate },
            set: { newValue in
                deleteRangeStartDate = newValue
                if deleteRangeEndDate < newValue {
                    deleteRangeEndDate = newValue
                }
                refreshDeleteRangeMatchCount()
            }
        )
    }

    private var deleteRangeEndBinding: Binding<Date> {
        Binding(
            get: { deleteRangeEndDate },
            set: { newValue in
                deleteRangeEndDate = max(newValue, deleteRangeStartDate)
                refreshDeleteRangeMatchCount()
            }
        )
    }

    private var deleteRangeCountDescription: String {
        if deleteRangeMatchCount == 0 {
            return "No photos match the selected date range."
        }

        return "\(deleteRangeMatchCount) photo\(deleteRangeMatchCount == 1 ? "" : "s") will be deleted."
    }

    private var deleteRangeConfirmationTitle: String {
        "Delete \(deleteRangeMatchCount) Photo\(deleteRangeMatchCount == 1 ? "" : "s")?"
    }

    private var deleteRangeConfirmationButtonTitle: String {
        "Delete \(deleteRangeMatchCount) Photo\(deleteRangeMatchCount == 1 ? "" : "s")"
    }

    private var deleteRangeConfirmationMessage: String {
        let formatter = Self.deleteRangeDateFormatter
        return "This will permanently delete \(deleteRangeMatchCount) photo\(deleteRangeMatchCount == 1 ? "" : "s") captured from \(formatter.string(from: deleteRangeStartDate)) to \(formatter.string(from: deleteRangeEndDate))."
    }

    @MainActor
    private func configureDeleteRange() async {
        let request = DailyPhoto.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \DailyPhoto.captureDate, ascending: true)]
        request.fetchLimit = 1

        if let earliestPhoto = try? viewContext.fetch(request).first,
           let earliestCaptureDate = earliestPhoto.captureDate {
            deleteRangeStartDate = Calendar.current.startOfDay(for: earliestCaptureDate)
        } else {
            deleteRangeStartDate = Calendar.current.startOfDay(for: Date())
        }

        deleteRangeEndDate = Calendar.current.startOfDay(for: Date())
        if deleteRangeEndDate < deleteRangeStartDate {
            deleteRangeEndDate = deleteRangeStartDate
        }

        refreshDeleteRangeMatchCount()
    }

    private func refreshDeleteRangeMatchCount() {
        let startDate = deleteRangeStartDate
        let endDate = deleteRangeEndDate

        deleteRangeStatusMessage = nil
        isLoadingDeleteRangeMatchCount = true

        Task { @MainActor in
            do {
                deleteRangeMatchCount = try await PhotoStorageService.shared.photoCount(
                    from: startDate,
                    to: endDate,
                    context: viewContext
                )
            } catch {
                deleteRangeMatchCount = 0
                deleteRangeStatusMessage = "Failed to count matching photos."
            }

            isLoadingDeleteRangeMatchCount = false
        }
    }

    @MainActor
    private func refreshTotalPhotoCount() async {
        isLoadingTotalPhotoCount = true
        defer { isLoadingTotalPhotoCount = false }

        do {
            let request = DailyPhoto.fetchRequest()
            totalPhotoCount = try viewContext.count(for: request)
        } catch {
            totalPhotoCount = 0
            deleteAllStatusMessage = "Failed to count stored photos."
        }
    }

    private func deletePhotosInSelectedRange() {
        guard !isDeletingPhotosInRange else { return }

        let startDate = deleteRangeStartDate
        let endDate = deleteRangeEndDate

        isDeletingPhotosInRange = true
        deleteRangeStatusMessage = nil

        Task { @MainActor in
            do {
                let deletedCount = try await PhotoStorageService.shared.deletePhotos(
                    from: startDate,
                    to: endDate,
                    context: viewContext
                )
                deleteRangeMatchCount = deletedCount
                deleteRangeStatusMessage = deletedCount == 1
                    ? "Deleted 1 photo."
                    : "Deleted \(deletedCount) photos."
                refreshDeleteRangeMatchCount()
                await refreshTotalPhotoCount()
                refreshLocalAssetStorageUsage()
            } catch {
                deleteRangeStatusMessage = "Failed to delete matching photos."
            }

            isDeletingPhotosInRange = false
        }
    }

    private func deleteAllPhotos() {
        guard !isDeletingAllPhotos else { return }

        isDeletingAllPhotos = true
        deleteAllStatusMessage = nil

        Task { @MainActor in
            do {
                let result = try await DeleteAllPhotosMaintenance.perform(
                    deletePhotos: {
                        try await PhotoStorageService.shared.deleteAllPhotos(context: viewContext)
                    },
                    purgeOrphanedAssets: { ignoreGracePeriod in
                        await PhotoStorageService.shared.purgeOrphanedAssets(
                            context: viewContext,
                            ignoreGracePeriod: ignoreGracePeriod
                        )
                    }
                )
                deleteAllStatusMessage = deleteAllStatusMessage(for: result)
                await configureDeleteRange()
                await refreshTotalPhotoCount()
                refreshLocalAssetStorageUsage()
            } catch {
                deleteAllStatusMessage = "Failed to delete all photos."
            }

            isDeletingAllPhotos = false
        }
    }

    private func deleteAllStatusMessage(for result: DeleteAllPhotosResult) -> String {
        let photoCountDescription = result.deletedCount == 1
            ? "Deleted 1 photo"
            : "Deleted \(result.deletedCount) photos"

        guard result.deletedCount > 0 else {
            return "There were no photos to delete."
        }

        guard !result.isCloudDeletionComplete else {
            return "\(photoCountDescription) from this device and iCloud."
        }

        if result.isDeferredUntilICloudAvailable {
            return "\(photoCountDescription) from this device. iCloud cleanup will resume automatically when iCloud is enabled."
        }

        switch result.cloudMetadataDeletionState {
        case .failed(let message):
            return "\(photoCountDescription) locally. iCloud metadata deletion still needs attention: \(message)"
        case .pending:
            if result.pendingRemoteAssetDeletionCount > 0 {
                return "\(photoCountDescription) locally. iCloud cleanup is still in progress for \(result.pendingRemoteAssetDeletionCount) asset\(result.pendingRemoteAssetDeletionCount == 1 ? "" : "s")."
            }
            return "\(photoCountDescription) locally. iCloud metadata deletion is still in progress."
        case .confirmed:
            return "\(photoCountDescription) locally. \(result.pendingRemoteAssetDeletionCount) iCloud asset deletion\(result.pendingRemoteAssetDeletionCount == 1 ? "" : "s") will keep retrying in the background."
        }
    }

    private func refreshLocalAssetStorageUsage() {
        isLoadingLocalAssetStorageUsage = true

        Task { @MainActor in
            localAssetStorageUsage = await CloudKitService.shared.localAssetStorageUsage()
            isLoadingLocalAssetStorageUsage = false
        }
    }

    private static let deleteRangeDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

@MainActor
enum DeleteAllPhotosMaintenance {
    static func perform(
        deletePhotos: () async throws -> DeleteAllPhotosResult,
        purgeOrphanedAssets: (Bool) async -> Void
    ) async throws -> DeleteAllPhotosResult {
        let result = try await deletePhotos()
        // Deleted photos already had their assets removed explicitly. Keep the
        // grace period for new captures that have staged bytes but no saved row yet.
        await purgeOrphanedAssets(false)
        return result
    }
}
