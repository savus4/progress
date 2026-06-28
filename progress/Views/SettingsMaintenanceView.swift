import SwiftUI
import CoreData

struct SettingsMaintenanceView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @StateObject private var cloudSyncMonitor = CloudSyncMonitor.shared

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
            Section("Storage") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(cloudSyncMonitor.isICloudUnavailable ? "Local Originals" : "System CloudKit Cache")
                        Spacer()
                        Text(PhotoAssetCacheSettings.formattedByteCount(primaryStorageUsageBytes))
                            .foregroundStyle(.secondary)
                    }

                    Text(cloudSyncMonitor.isICloudUnavailable
                         ? "Full-resolution originals stay on this device and are included in device backup until iCloud sync resumes."
                         : "Fetched originals live in CloudKit's system-managed cache. Pending Uploads stay local until iCloud has a copy.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Cached")
                    Spacer()
                    if isLoadingLocalAssetStorageUsage {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(storageUsageDescription)
                            .foregroundStyle(.secondary)
                    }
                }

                if localAssetStorageUsage.pendingUploadBytes > 0 {
                    Text(cloudSyncMonitor.isICloudUnavailable
                         ? "Local originals use \(PhotoAssetCacheSettings.formattedByteCount(localAssetStorageUsage.pendingUploadBytes)) and are included in device backup."
                         : "Pending uploads use \(PhotoAssetCacheSettings.formattedByteCount(localAssetStorageUsage.pendingUploadBytes)) until iCloud has a copy.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

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
                .disabled(deleteRangeMatchCount == 0 || isDeletingPhotosInRange || isLoadingDeleteRangeMatchCount)

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
                .disabled(totalPhotoCount == 0 || isDeletingAllPhotos || isLoadingTotalPhotoCount)

                if let deleteAllStatusMessage {
                    Text(deleteAllStatusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Storage Management")
        .navigationBarTitleDisplayMode(.inline)
        .task {
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

    private var storageUsageDescription: String {
        PhotoAssetCacheSettings.formattedByteCount(primaryStorageUsageBytes)
    }

    private var primaryStorageUsageBytes: Int {
        cloudSyncMonitor.isICloudUnavailable
            ? localAssetStorageUsage.pendingUploadBytes
            : localAssetStorageUsage.cachedFullResolutionBytes
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
                let result = try await PhotoStorageService.shared.deleteAllPhotos(context: viewContext)
                await PhotoStorageService.shared.purgeOrphanedAssets(
                    context: viewContext,
                    ignoreGracePeriod: true
                )
                if result.shouldRebuildPersistentStore {
                    try await PersistenceController.shared.rebuildPersistentStore()
                }
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
