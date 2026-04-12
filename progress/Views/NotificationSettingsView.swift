import SwiftUI
import UserNotifications
import UIKit
import PhotosUI
import CoreData
import CoreTransferable
import Photos
import os

struct NotificationSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext
    @StateObject private var cloudSyncMonitor = CloudSyncMonitor.shared

    @State private var reminderTimes: [DailyReminderTime] = []
    @State private var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @State private var didPersistChanges = false

    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var selectedPrivatePhotoItems: [PhotosPickerItem] = []
    @State private var showingAlbumImportSheet = false
    @State private var availableImportAlbums: [ImportAlbum] = []
    @State private var isLoadingImportAlbums = false
    @State private var isImportingPhotos = false
    @State private var importTotalCount = 0
    @State private var importedCount = 0
    @State private var duplicateImportCount = 0
    @State private var failedImportCount = 0
    @State private var importStatusMessage: String?
    @State private var importFailureMessages: [String] = []
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
    @State private var isRetryingUploads = false
    @State private var uploadRetryStatusMessage: String?

    private let notificationService = DailyReminderNotificationService.shared
    private let importLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "progress", category: "PhotoImport")
    private let importFlushSize = 3

    var body: some View {
        NavigationStack {
            Form {
                Section("Notifications") {
                    if reminderTimes.isEmpty {
                        Text("No reminder times configured.")
                            .foregroundStyle(.secondary)
                    }

                    ForEach($reminderTimes) { $reminder in
                        HStack {
                            DatePicker(
                                "",
                                selection: Binding(
                                    get: { reminder.dateValue },
                                    set: { newDate in
                                        reminder = DailyReminderTime(id: reminder.id, date: newDate)
                                    }
                                ),
                                displayedComponents: .hourAndMinute
                            )
                            .labelsHidden()

                            Spacer()

                            Button(role: .destructive) {
                                removeReminder(withID: reminder.id)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove reminder")
                        }
                    }

                    Button {
                        addReminder()
                    } label: {
                        Label("Add Time", systemImage: "plus.circle")
                    }
                    .disabled(reminderTimes.count >= DailyReminderNotificationService.maxRemindersPerDay)

                    if reminderTimes.count >= DailyReminderNotificationService.maxRemindersPerDay {
                        Text("You can select up to three reminders per day.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Text(permissionDescription)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if authorizationStatus == .denied {
                        Button("Open System Settings") {
                            openAppSettings()
                        }
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: reminderTimes)

                Section("Import") {
                    PhotosPicker(
                        selection: $selectedPhotoItems,
                        maxSelectionCount: nil,
                        matching: .any(of: [.images, .livePhotos]),
                        photoLibrary: .shared()
                    ) {
                        Label("Import Photos", systemImage: "photo.on.rectangle.angled")
                    }
                    .disabled(isImportingPhotos)

                    PhotosPicker(
                        selection: $selectedPrivatePhotoItems,
                        maxSelectionCount: nil,
                        matching: .any(of: [.images, .livePhotos]),
                        photoLibrary: .shared()
                    ) {
                        Label("Import Privately (Experimental)", systemImage: "lock.shield")
                    }
                    .disabled(isImportingPhotos)

                    Button {
                        presentAlbumImportSheet()
                    } label: {
                        Label("Import Album", systemImage: "rectangle.stack")
                    }
                    .disabled(isImportingPhotos || isLoadingImportAlbums)

                    Text("Standard import preserves Live Photos. Private import remains experimental and may import Live Photos as still images.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if isImportingPhotos {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: Double(processedImportCount), total: Double(max(importTotalCount, 1)))
                            Text(importProgressDescription)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let importStatusMessage {
                        Text(importStatusMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("iCloud Sync") {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: cloudSyncMonitor.statusSymbolName)
                            .font(.title3)
                            .foregroundStyle(cloudSyncMonitor.isFailing ? .red : .secondary)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(cloudSyncMonitor.statusTitle)
                            Text(cloudSyncMonitor.statusDetail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if cloudSyncMonitor.hasRetryableUploads || isRetryingUploads {
                        Button {
                            retryFailedUploads()
                        } label: {
                            if isRetryingUploads {
                                Label("Retrying Uploads…", systemImage: "arrow.triangle.2.circlepath")
                            } else {
                                Label("Retry Failed Uploads Now", systemImage: "arrow.clockwise")
                            }
                        }
                        .disabled(isRetryingUploads || !cloudSyncMonitor.hasRetryableUploads)
                    }

                    if let uploadRetryStatusMessage {
                        Text(uploadRetryStatusMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
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
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .disabled(isImportingPhotos)
                }
            }
            .task {
                reminderTimes = notificationService.loadReminderTimes()
                authorizationStatus = await notificationService.authorizationStatus()
                await cloudSyncMonitor.refreshUploadStatus()
                await configureDeleteRange()
                await refreshTotalPhotoCount()
            }
            .onChange(of: selectedPhotoItems) { _, items in
                guard !items.isEmpty else { return }
                importSelectedPhotos(items)
            }
            .onChange(of: selectedPrivatePhotoItems) { _, items in
                guard !items.isEmpty else { return }
                importSelectedPhotosPrivately(items)
            }
            .onDisappear {
                persistChangesIfNeeded()
            }
            .sheet(isPresented: $showingAlbumImportSheet) {
                NavigationStack {
                    Group {
                        if availableImportAlbums.isEmpty {
                            ContentUnavailableView(
                                "No Albums Available",
                                systemImage: "rectangle.stack",
                                description: Text("Grant Photos access and make sure the selected albums contain photos.")
                            )
                        } else {
                            List(availableImportAlbums) { album in
                                Button {
                                    startImportFromAlbum(album)
                                } label: {
                                    HStack(spacing: 12) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(album.title)
                                                .foregroundStyle(.primary)
                                            Text("\(album.assetCount) photo\(album.assetCount == 1 ? "" : "s")")
                                                .font(.footnote)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.footnote.weight(.semibold))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                    }
                    .navigationTitle("Import Album")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") {
                                showingAlbumImportSheet = false
                            }
                        }
                    }
                }
            }
            .interactiveDismissDisabled(isImportingPhotos)
            .alert(
                deleteRangeConfirmationTitle,
                isPresented: $showingDeleteRangeConfirmation,
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
                Text("This will permanently delete every photo from Work in Progress and remove the stored local assets on this device.")
            }
        }
    }

    private var permissionDescription: String {
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return "Notifications are enabled."
        case .notDetermined:
            return "Permission will be requested when you leave this screen with reminders configured."
        case .denied:
            return "Notifications are turned off for this app. Enable them in Settings."
        @unknown default:
            return "Notification permission status is unavailable."
        }
    }

    private func addReminder() {
        guard reminderTimes.count < DailyReminderNotificationService.maxRemindersPerDay else { return }

        let defaultHourCandidates = [9, 13, 20]
        let index = min(reminderTimes.count, defaultHourCandidates.count - 1)
        let newReminder = DailyReminderTime(hour: defaultHourCandidates[index], minute: 0)

        withAnimation(.easeInOut(duration: 0.2)) {
            reminderTimes.append(newReminder)
        }
    }

    private func removeReminder(withID id: UUID) {
        withAnimation(.easeInOut(duration: 0.2)) {
            reminderTimes.removeAll { $0.id == id }
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

    private var processedImportCount: Int {
        importedCount + duplicateImportCount + failedImportCount
    }

    private var importProgressDescription: String {
        let processed = processedImportCount
        let importedSummary = importedCount == 0 ? nil : "\(importedCount) imported"
        let duplicateSummary = duplicateImportCount == 0 ? nil : "\(duplicateImportCount) skipped"
        let failureSummary = failedImportCount == 0 ? nil : "\(failedImportCount) failed"
        let summaries = [importedSummary, duplicateSummary, failureSummary].compactMap(\.self)

        if summaries.isEmpty {
            return "Importing \(processed) of \(importTotalCount)"
        }

        return "Importing \(processed) of \(importTotalCount) (\(summaries.joined(separator: ", ")))"
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

    private func importSelectedPhotos(_ items: [PhotosPickerItem]) {
        beginImport(totalCount: items.count) {
            await importItems(items, preserveLivePhotos: true)
        }
    }

    private func importSelectedPhotosPrivately(_ items: [PhotosPickerItem]) {
        beginImport(totalCount: items.count) {
            await importItems(items, preserveLivePhotos: false)
        }
    }

    private func beginImport(totalCount: Int, operation: @escaping @Sendable () async -> Void) {
        guard !isImportingPhotos else { return }

        isImportingPhotos = true
        importTotalCount = totalCount
        importedCount = 0
        duplicateImportCount = 0
        failedImportCount = 0
        importStatusMessage = nil
        importFailureMessages = []

        Task {
            await operation()
        }
    }

    private func persistChangesIfNeeded() {
        guard !didPersistChanges else { return }
        didPersistChanges = true

        Task {
            _ = await notificationService.updateReminderTimes(reminderTimes)
            authorizationStatus = await notificationService.authorizationStatus()
        }
    }

    private func openAppSettings() {
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(settingsURL)
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
                let deletedCount = try await PhotoStorageService.shared.deleteAllPhotos(context: viewContext)
                await PhotoStorageService.shared.purgeOrphanedAssets(context: viewContext)
                deleteAllStatusMessage = deletedCount == 1
                    ? "Deleted 1 photo."
                    : "Deleted \(deletedCount) photos."
                await configureDeleteRange()
                await refreshTotalPhotoCount()
            } catch {
                deleteAllStatusMessage = "Failed to delete all photos."
            }

            isDeletingAllPhotos = false
        }
    }

    private func retryFailedUploads() {
        guard !isRetryingUploads else { return }

        isRetryingUploads = true
        uploadRetryStatusMessage = nil

        Task { @MainActor in
            let retriedCount = await PhotoUploadService.shared.retryFailedUploads()
            await cloudSyncMonitor.refreshUploadStatus()

            if retriedCount == 0 {
                uploadRetryStatusMessage = "There were no uploads to retry."
            } else if retriedCount == 1 {
                uploadRetryStatusMessage = "Retried 1 upload."
            } else {
                uploadRetryStatusMessage = "Retried \(retriedCount) uploads."
            }

            isRetryingUploads = false
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
        let totals = await MainActor.run { () -> (imported: Int, duplicates: Int, failed: Int) in
            let imported = importedCount
            let duplicates = duplicateImportCount
            let failed = failedImportCount

            isImportingPhotos = false
            selectedPhotoItems = []
            selectedPrivatePhotoItems = []

            if failed == 0 {
                let baseMessage = preserveLivePhotos
                    ? "Imported \(imported) photo\(imported == 1 ? "" : "s")."
                    : "Imported \(imported) photo\(imported == 1 ? "" : "s") using private mode."
                if duplicates > 0 {
                    importStatusMessage = "\(baseMessage) Skipped \(duplicates) duplicate picture\(duplicates == 1 ? "" : "s")."
                } else {
                    importStatusMessage = baseMessage
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
                importStatusMessage = failureSummary.isEmpty ? summary : "\(summary) \(failureSummary)"
            }

            return (imported, duplicates, failed)
        }

        importLogger.log(
            "\(logPrefix, privacy: .public) total=\(totalCount, privacy: .public) imported=\(totals.imported, privacy: .public) duplicates=\(totals.duplicates, privacy: .public) failed=\(totals.failed, privacy: .public) elapsed=\(String(describing: elapsed), privacy: .public)"
        )
    }

    private func presentAlbumImportSheet() {
        guard !isImportingPhotos, !isLoadingImportAlbums else { return }
        isLoadingImportAlbums = true

        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            guard status == .authorized || status == .limited else {
                await MainActor.run {
                    isLoadingImportAlbums = false
                    importStatusMessage = "Photos access is required to import an album."
                }
                return
            }

            let albums = loadImportAlbums()
            await MainActor.run {
                availableImportAlbums = albums
                isLoadingImportAlbums = false
                showingAlbumImportSheet = true
            }
        }
    }

    private func loadImportAlbums() -> [ImportAlbum] {
        let assetOptions = PHFetchOptions()
        assetOptions.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)

        var albums: [ImportAlbum] = []

        func appendAlbums(from fetchResult: PHFetchResult<PHAssetCollection>) {
            fetchResult.enumerateObjects { collection, _, _ in
                let count = PHAsset.fetchAssets(in: collection, options: assetOptions).count
                guard count > 0 else { return }
                albums.append(
                    ImportAlbum(
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
                ImportAlbum(
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

    private func startImportFromAlbum(_ album: ImportAlbum) {
        let fetchResult = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [album.localIdentifier], options: nil)
        guard let collection = fetchResult.firstObject else {
            importStatusMessage = "The selected album is no longer available."
            showingAlbumImportSheet = false
            return
        }

        let assetOptions = PHFetchOptions()
        assetOptions.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        let assets = allObjects(from: PHAsset.fetchAssets(in: collection, options: assetOptions))

        showingAlbumImportSheet = false
        beginImport(totalCount: assets.count) {
            await importAssets(assets, preserveLivePhotos: true)
        }
    }

    private func flushImportedPayloads(_ payloads: inout [ImportedPhotoPayload]) async {
        let chunk = payloads
        payloads.removeAll(keepingCapacity: true)

        let result = await PhotoStorageService.shared.saveImportedPhotos(chunk, batchSize: importFlushSize)
        await MainActor.run {
            importedCount += result.importedCount
            duplicateImportCount += result.duplicateCount
            failedImportCount += result.failedCount
            importFailureMessages.append(contentsOf: result.failureMessages)
            if importFailureMessages.count > 20 {
                importFailureMessages = Array(importFailureMessages.prefix(20))
            }
        }
    }

    private func recordImportFailure(stage: String, itemIdentifier: String?, message: String) async {
        let identifier = itemIdentifier ?? "unknown"
        let logMessage = "\(stage) item=\(identifier): \(message)"
        importLogger.error("\(logMessage, privacy: .public)")

        await MainActor.run {
            failedImportCount += 1

            if importFailureMessages.count < 20 {
                importFailureMessages.append(logMessage)
            }
        }
    }

    private static let deleteRangeDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

private struct ImportedPickerImageFile: Transferable {
    let fileURL: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            Self(fileURL: try ImportedPickerFileCopier.makeTemporaryCopy(of: received.file))
        }
    }
}

private struct ImportedPickerMovieFile: Transferable {
    let fileURL: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
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

private extension DailyReminderTime {
    init(id: UUID, date: Date) {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        self.id = id
        self.hour = components.hour ?? 9
        self.minute = components.minute ?? 0
    }
}

private struct ImportAlbum: Identifiable {
    let localIdentifier: String
    let title: String
    let assetCount: Int

    var id: String { localIdentifier }

    var isPrimaryLibraryAlbum: Bool {
        let normalizedTitle = title.lowercased()
        return normalizedTitle == "library" || normalizedTitle == "recents"
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
