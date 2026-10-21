import SwiftUI

struct NotificationSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var cloudSyncMonitor = CloudSyncMonitor.shared
    @StateObject private var photoImporter = PhotoImportCoordinator.shared
    @State private var storage = PhotoStorageCoordinator.shared
    @State private var navigationPath: [PhotoSettingsDestination]
    @AppStorage(CameraPreferenceKey.hirsModeEnabled) private var isHirsModeEnabled = false
    @AppStorage(IntroductionPreferences.completedKey) private var hasCompletedIntroduction = false

    @State private var isRetryingUploads = false
    @State private var uploadRetryStatusMessage: String?
    @State private var bottomRubberBandDistance: CGFloat = 0
    @State private var showsIntroductionScheduledAlert = false

    private let settingsCreditRevealOverscroll: CGFloat = 190
    private let settingsCreditFadeOverscroll: CGFloat = 40

    init(opensPhotoStorage: Bool = false) {
        _navigationPath = State(initialValue: opensPhotoStorage ? [.photoStorage] : [])
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Form {
                Section("iCloud Sync") {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: cloudSyncMonitor.statusSymbolName)
                            .font(.title3)
                            .foregroundStyle(cloudSyncMonitor.isFailing ? .red : .secondary)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(cloudSyncMonitor.statusTitle)
                            if cloudSyncMonitor.showsStatusDetail {
                                Text(cloudSyncMonitor.statusDetail)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if !storage.isLocalOnly && (cloudSyncMonitor.hasRetryableUploads || isRetryingUploads) {
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

                    NavigationLink(value: PhotoSettingsDestination.photoStorage) {
                        Label("Photo Storage", systemImage: storage.isLocalOnly ? "iphone" : "icloud")
                    }
                    .accessibilityIdentifier("photoStorageSettingsLink")
                }

                Section {
                    NavigationLink {
                        DailyReminderSettingsView()
                    } label: {
                        Label("Notifications", systemImage: "bell.badge")
                    }
                    .accessibilityIdentifier("notificationSettingsLink")

                    NavigationLink {
                        PhotoImportSettingsView()
                    } label: {
                        Label("Import", systemImage: "square.and.arrow.down")
                    }
                    .accessibilityIdentifier("importSettingsLink")
                }

                Section("Camera") {
                    Toggle("Hirs-Mode", isOn: $isHirsModeEnabled)
                        .accessibilityIdentifier("hirsModeToggle")

                    Text("Shows the photo preview mirrored, matching the camera preview. Saved photos stay unchanged.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                TipJarSection()
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                let bottomEdge = geometry.contentOffset.y + geometry.containerSize.height - geometry.contentInsets.bottom
                let visibleHeight = geometry.containerSize.height - geometry.contentInsets.top - geometry.contentInsets.bottom
                // Empty space below a short form is not overscroll.
                let restingBottomEdge = max(geometry.contentSize.height, visibleHeight)
                return max(0, bottomEdge - restingBottomEdge)
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
            .navigationDestination(for: PhotoSettingsDestination.self) { destination in
                switch destination {
                case .general, .photoStorage:
                    PhotoStorageSettingsView()
                case .storageManagement:
                    SettingsMaintenanceView()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Settings")
                        .font(.headline)
                        .padding(.horizontal, 24)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("settingsTitle")
                        .onLongPressGesture(minimumDuration: 3, perform: scheduleIntroduction)
                        .accessibilityAction(named: Text("Show Introduction on Next Launch")) {
                            scheduleIntroduction()
                        }
                }
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
                await cloudSyncMonitor.refreshUploadStatus()
            }
            .alert("Introduction Scheduled", isPresented: $showsIntroductionScheduledAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("The introduction will appear the next time you launch Work in Progress.")
            }
        }
    }

    private func scheduleIntroduction() {
        hasCompletedIntroduction = false
        showsIntroductionScheduledAlert = true
    }

    private var settingsCreditFooterOpacity: CGFloat {
        settingsCreditOpacity(startingAt: settingsCreditRevealOverscroll)
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

}
