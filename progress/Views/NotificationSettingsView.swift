import SwiftUI
import UserNotifications
import UIKit
import PhotosUI
import Photos

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
    @State private var failedImportCount = 0
    @State private var importStatusMessage: String?

    private let notificationService = DailyReminderNotificationService.shared

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

                    Text("Experimental: imports picker-provided representations without Photo Library resource access. Live Photos may import as still images.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if isImportingPhotos {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: Double(importedCount + failedImportCount), total: Double(max(importTotalCount, 1)))
                            Text("Importing \(importedCount + failedImportCount) of \(importTotalCount)")
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

    private func importSelectedPhotos(_ items: [PhotosPickerItem]) {
        guard !isImportingPhotos else { return }

        isImportingPhotos = true
        importTotalCount = items.count
        importedCount = 0
        failedImportCount = 0
        importStatusMessage = nil

        Task { @MainActor in
            for item in items {
                do {
                    if let livePhotoImport = try await loadLivePhotoImportResources(for: item) {
                        defer {
                            try? FileManager.default.removeItem(at: livePhotoImport.videoURL)
                        }
                        _ = try await PhotoStorageService.shared.saveImportedLivePhoto(
                            imageData: livePhotoImport.imageData,
                            videoURL: livePhotoImport.videoURL,
                            context: viewContext
                        )
                    } else {
                        guard let imageData = try await item.loadTransferable(type: Data.self) else {
                            failedImportCount += 1
                            continue
                        }

                        _ = try await PhotoStorageService.shared.saveImportedPhoto(
                            imageData: imageData,
                            context: viewContext
                        )
                    }

                    importedCount += 1
                } catch {
                    failedImportCount += 1
                }
            }

            isImportingPhotos = false
            selectedPhotoItems = []

            if failedImportCount == 0 {
                importStatusMessage = "Imported \(importedCount) photo\(importedCount == 1 ? "" : "s")."
            } else {
                importStatusMessage = "Imported \(importedCount), failed \(failedImportCount)."
            }
        }
    }

    private func importSelectedPhotosPrivately(_ items: [PhotosPickerItem]) {
        guard !isImportingPhotos else { return }

        isImportingPhotos = true
        importTotalCount = items.count
        importedCount = 0
        failedImportCount = 0
        importStatusMessage = nil

        Task { @MainActor in
            for item in items {
                do {
                    guard let imageData = try await item.loadTransferable(type: Data.self) else {
                        failedImportCount += 1
                        continue
                    }

                    _ = try await PhotoStorageService.shared.saveImportedPhoto(
                        imageData: imageData,
                        context: viewContext
                    )

                    importedCount += 1
                } catch {
                    failedImportCount += 1
                }
            }

            isImportingPhotos = false
            selectedPrivatePhotoItems = []

            if failedImportCount == 0 {
                importStatusMessage = "Imported \(importedCount) photo\(importedCount == 1 ? "" : "s") using private mode."
            } else {
                importStatusMessage = "Private import: imported \(importedCount), failed \(failedImportCount)."
            }
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

    private func loadLivePhotoImportResources(for item: PhotosPickerItem) async throws -> (imageData: Data, videoURL: URL)? {
        guard let identifier = item.itemIdentifier else { return nil }

        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = fetchResult.firstObject else { return nil }

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
        let suffix = originalExtension.isEmpty ? "" : ".\(originalExtension)"
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)\(suffix)")

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
}

private extension DailyReminderTime {
    init(id: UUID, date: Date) {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        self.id = id
        self.hour = components.hour ?? 9
        self.minute = components.minute ?? 0
    }
}
