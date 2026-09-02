import SwiftUI
import UserNotifications
import UIKit
import PhotosUI

struct NotificationSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var cloudSyncMonitor = CloudSyncMonitor.shared
    @StateObject private var photoImporter = PhotoImportCoordinator.shared
    @AppStorage(CameraPreferenceKey.hirsModeEnabled) private var isHirsModeEnabled = false

    @State private var reminderTimes: [DailyReminderTime] = []
    @State private var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @State private var didPersistChanges = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var selectedPrivatePhotoItems: [PhotosPickerItem] = []
    @State private var showingAlbumImportSheet = false
    @State private var availableImportAlbums: [PhotoImportAlbum] = []
    @State private var isLoadingImportAlbums = false
    @State private var isRetryingUploads = false
    @State private var uploadRetryStatusMessage: String?
    @State private var bottomRubberBandDistance: CGFloat = 0

    private let notificationService = DailyReminderNotificationService.shared
    private let settingsCreditRevealOverscroll: CGFloat = 190
    private let settingsCreditPlaceholderRevealOverscroll: CGFloat = 420
    private let settingsCreditFadeOverscroll: CGFloat = 40

    var body: some View {
        NavigationStack {
            Form {
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
                            .foregroundStyle(reminderTimes.count >= DailyReminderNotificationService.maxRemindersPerDay ? Color.secondary : Color.accentColor)
                    }
                    .disabled(reminderTimes.count >= DailyReminderNotificationService.maxRemindersPerDay)

                    if reminderTimes.count >= DailyReminderNotificationService.maxRemindersPerDay {
                        Text("You can select up to five reminders per day.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if let permissionDescription {
                        Text(permissionDescription)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

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
                    .disabled(photoImporter.isImporting)

                    Button {
                        presentAlbumImportSheet()
                    } label: {
                        Label("Import Album", systemImage: "rectangle.stack")
                    }
                    .disabled(photoImporter.isImporting || isLoadingImportAlbums)

                    PhotosPicker(
                        selection: $selectedPrivatePhotoItems,
                        maxSelectionCount: nil,
                        matching: .any(of: [.images, .livePhotos]),
                        photoLibrary: .shared()
                    ) {
                        Label("Import Privately (No Live Photos)", systemImage: "lock.shield")
                    }
                    .disabled(photoImporter.isImporting)

                    importGuidanceCard

                    if let statusMessage = photoImporter.statusMessage {
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Camera") {
                    Toggle("Hirs-Mode", isOn: $isHirsModeEnabled)
                        .accessibilityIdentifier("hirsModeToggle")

                    Text("Shows the photo preview mirrored, matching the camera preview. Saved photos stay unchanged.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    NavigationLink {
                        SettingsMaintenanceView()
                    } label: {
                        Label("Storage Management", systemImage: "internaldrive")
                    }
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                let bottomEdge = geometry.contentOffset.y + geometry.containerSize.height - geometry.contentInsets.bottom
                return max(0, bottomEdge - geometry.contentSize.height)
            } action: { _, newDistance in
                bottomRubberBandDistance = newDistance
            }

            .overlay(alignment: .bottom) {
                if bottomRubberBandDistance > settingsCreditRevealOverscroll {
                    settingsCreditFooter
                        .opacity(settingsCreditFooterOpacity)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) {
                if photoImporter.shouldShowOverlay {
                    PhotoImportProgressOverlay(importer: photoImporter)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 20)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(.primary)
                    }
                    .accessibilityLabel("Close")
                }
            }
            .task {
                reminderTimes = notificationService.loadReminderTimes()
                authorizationStatus = await notificationService.authorizationStatus()
                await cloudSyncMonitor.refreshUploadStatus()
            }
            .onChange(of: selectedPhotoItems) { _, items in
                guard !items.isEmpty else { return }
                photoImporter.importSelectedPhotos(items)
                selectedPhotoItems = []
            }
            .onChange(of: selectedPrivatePhotoItems) { _, items in
                guard !items.isEmpty else { return }
                photoImporter.importSelectedPhotosPrivately(items)
                selectedPrivatePhotoItems = []
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
        }
    }

    private var permissionDescription: String? {
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return nil
        case .notDetermined:
            return "Permission will be requested when you leave this screen with reminders configured."
        case .denied:
            return "Notifications are turned off for this app. Enable them in Settings."
        @unknown default:
            return "Notification permission status is unavailable."
        }
    }

    private var importGuidanceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            importGuidanceRow(
                systemImage: "livephoto",
                title: "Live Photos",
                detail: "\"Import Photos\" and \"Import Album\" keep Live Photos, great for video creation.",
                tint: .blue
            )

            Divider()

            importGuidanceRow(
                systemImage: "photo",
                title: "Private Import",
                detail: "\"Import Privately\" saves still images only, and you can import without full Photos library access.",
                tint: .orange
            )

            Divider()

            importGuidanceRow(
                systemImage: "lock.shield",
                title: "Your Data",
                detail: "Photos stay on this device and, when enabled, in your iCloud.",
                tint: .green
            )
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    @ViewBuilder
    private func importGuidanceRow(
        systemImage: String,
        title: String,
        detail: String,
        tint: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.footnote.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var settingsCreditFooterOpacity: CGFloat {
        settingsCreditOpacity(startingAt: settingsCreditRevealOverscroll)
    }

    private var settingsCreditPlaceholderOpacity: CGFloat {
        settingsCreditOpacity(startingAt: settingsCreditPlaceholderRevealOverscroll)
    }

    private var settingsCreditFooter: some View {
        VStack(spacing: 6) {
            Text("Made by Simon Riepl")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text("🐢")
                .font(.title3)
                .accessibilityHidden(true)

            Text(appVersionDescription)
                .font(.caption2)
                .foregroundStyle(Color.secondary.opacity(0.45))

            Text("Hi Elin 👋")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .opacity(settingsCreditPlaceholderOpacity)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Made by Simon Riepl. \(appVersionAccessibilityDescription)")
    }

    private var appVersionDescription: String {
        "v\(appVersion) (\(appBuild))"
    }

    private var appVersionAccessibilityDescription: String {
        "Version \(appVersion), build \(appBuild)"
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    private var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
    }

    private func settingsCreditOpacity(startingAt overscroll: CGFloat) -> CGFloat {
        min(1, max(0, (bottomRubberBandDistance - overscroll) / settingsCreditFadeOverscroll))
    }

    private func addReminder() {
        guard reminderTimes.count < DailyReminderNotificationService.maxRemindersPerDay else { return }

        let defaultHourCandidates = [9, 12, 15, 18, 21]
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

    private func presentAlbumImportSheet() {
        guard !photoImporter.isImporting, !isLoadingImportAlbums else { return }
        isLoadingImportAlbums = true

        Task { @MainActor in
            availableImportAlbums = await photoImporter.requestImportAlbums()
            isLoadingImportAlbums = false
            showingAlbumImportSheet = !availableImportAlbums.isEmpty
        }
    }

    private func startImportFromAlbum(_ album: PhotoImportAlbum) {
        showingAlbumImportSheet = false
        photoImporter.importAlbum(album)
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
