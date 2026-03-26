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

    @State private var reminderTimes: [DailyReminderTime] = []
    @State private var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @State private var didPersistChanges = false

    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var selectedPrivatePhotoItems: [PhotosPickerItem] = []
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

    private let notificationService = DailyReminderNotificationService.shared
    private let importLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "progress", category: "PhotoImport")

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
                await configureDeleteRange()
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
        guard !isImportingPhotos else { return }

        isImportingPhotos = true
        importTotalCount = items.count
        importedCount = 0
        duplicateImportCount = 0
        failedImportCount = 0
        importStatusMessage = nil
        importFailureMessages = []

        Task {
            await importItems(items, preserveLivePhotos: true)
        }
    }

    private func importSelectedPhotosPrivately(_ items: [PhotosPickerItem]) {
        guard !isImportingPhotos else { return }

        isImportingPhotos = true
        importTotalCount = items.count
        importedCount = 0
        duplicateImportCount = 0
        failedImportCount = 0
        importStatusMessage = nil
        importFailureMessages = []

        Task {
            await importItems(items, preserveLivePhotos: false)
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
                deleteRangeMatchCount = try PhotoStorageService.shared.photoCount(
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
            } catch {
                deleteRangeStatusMessage = "Failed to delete matching photos."
            }

            isDeletingPhotosInRange = false
        }
    }

    private func loadLivePhotoImportResources(for item: PhotosPickerItem) async throws -> (imageData: Data, videoURL: URL)? {
        guard let identifier = item.itemIdentifier else { return nil }

        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = fetchResult.firstObject else { return nil }
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

    private func writeResourceToTemporaryFile(_ resource: PHAssetResource) async throws -> URL {
        let originalExtension = URL(fileURLWithPath: resource.originalFilename).pathExtension
        var destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)

        if !originalExtension.isEmpty {
            destinationURL.appendPathExtension(originalExtension)
        }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

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
    }

    private func importItems(_ items: [PhotosPickerItem], preserveLivePhotos: Bool) async {
        let chunkSize = 10
        let clock = ContinuousClock()
        let startedAt = clock.now

        var pendingPayloads: [ImportedPhotoPayload] = []
        pendingPayloads.reserveCapacity(chunkSize)

        for item in items {
            do {
                if preserveLivePhotos,
                   let livePhotoImport = try await loadLivePhotoImportResources(for: item) {
                    pendingPayloads.append(
                        ImportedPhotoPayload(
                            imageData: livePhotoImport.imageData,
                            livePhotoVideoURL: livePhotoImport.videoURL
                        )
                    )
                } else {
                    guard let importedFile = try await item.loadTransferable(type: ImportedPickerImageFile.self) else {
                        await recordImportFailure(
                            stage: "picker-transfer",
                            itemIdentifier: item.itemIdentifier,
                            message: "No transferable image file was returned."
                        )
                        continue
                    }

                    let imageData = try Data(contentsOf: importedFile.fileURL)
                    pendingPayloads.append(ImportedPhotoPayload(imageData: imageData))
                    try? FileManager.default.removeItem(at: importedFile.fileURL)
                }
            } catch {
                let stage = preserveLivePhotos ? "item-load" : "private-item-load"
                await recordImportFailure(
                    stage: stage,
                    itemIdentifier: item.itemIdentifier,
                    message: error.localizedDescription
                )
            }

            if pendingPayloads.count >= chunkSize {
                await flushImportedPayloads(&pendingPayloads)
            }
        }

        if !pendingPayloads.isEmpty {
            await flushImportedPayloads(&pendingPayloads)
        }

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
            "Settings import finished. total=\(items.count, privacy: .public) imported=\(totals.imported, privacy: .public) duplicates=\(totals.duplicates, privacy: .public) failed=\(totals.failed, privacy: .public) elapsed=\(String(describing: elapsed), privacy: .public)"
        )
    }

    private func flushImportedPayloads(_ payloads: inout [ImportedPhotoPayload]) async {
        let chunk = payloads
        payloads.removeAll(keepingCapacity: true)

        let result = await PhotoStorageService.shared.saveImportedPhotos(chunk)
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
