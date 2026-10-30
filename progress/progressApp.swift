//
//  progressApp.swift
//  progress
//
//  Created by Simon Riepl on 19.02.26.
//

import SwiftUI
import CoreData
import UserNotifications
import OSLog

@main
struct progressApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var persistenceController = PersistenceController.shared
    @State private var tipStore = TipStore()

    init() {
        loadRocketSimConnect()
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["UI_TEST_RESET_REMINDERS"] == "1" {
            UserDefaults.standard.removeObject(forKey: "dailyPhotoReminderTimes")
            UserDefaults.standard.removeObject(forKey: DailyReminderNotificationService.skipAfterPhotoKey)
            UserDefaults.standard.removeObject(forKey: DailyReminderNotificationService.timelinePreferencesKey)
        }
        if ProcessInfo.processInfo.environment["UI_TEST_RESET_TIMELINES"] == "1" {
            UserDefaults.standard.removeObject(forKey: TimelineSelectionStore.selectedTimelineKey)
        }
        #endif
    }

    var body: some Scene {
        // WindowGroup's deferred builder can run on SwiftUI.AsyncRenderer.
        // Construct actor-isolated content here, before handing it to SwiftUI.
        let rootView = AppRootView(
            persistenceController: persistenceController,
            tipStore: tipStore,
            onPersistenceLoaded: appDelegate.startPersistenceServices
        )
        return WindowGroup { @Sendable in
            rootView
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                appDelegate.handleBecameActive()
            case .background:
                appDelegate.handleEnteredBackground()
            default:
                break
            }
        }
    }

    private func loadRocketSimConnect() {
        #if DEBUG && targetEnvironment(simulator)
        // Core Data inspection can deadlock the app; enable only when needed.
        guard ProcessInfo.processInfo.environment["ROCKETSIM_CONNECT_ENABLED"] == "1" else { return }
        guard (Bundle(path: "/Applications/RocketSim.app/Contents/Frameworks/RocketSimConnectLinker.nocache.framework")?.load() == true) else {
            print("Failed to load linker framework")
            return
        }
        print("RocketSim Connect successfully linked")
        #endif
    }
}

struct PersistenceRootView: View {
    @ObservedObject var persistenceController: PersistenceController

    var body: some View {
        switch persistenceController.loadState {
        case .loading:
            LibraryLoadingView()
        case .loaded:
            if StorageTestConfiguration.isIsolatedHost {
                Color.clear
            } else {
                ContentView()
                    .environment(\.managedObjectContext, persistenceController.container.viewContext)
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Library Couldn’t Open", systemImage: "externaldrive.badge.exclamationmark")
            } description: {
                Text("Your photos remain stored. Nothing was deleted.\n\n\(message)")
            } actions: {
                Button("Try Again") {
                    persistenceController.retryLoading()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

private struct LibraryLoadingView: View {
    @State private var placeholderOpacity = 0.45
    @State private var showsDelayedIndicator = false

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 2),
        count: 3
    )

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(0..<18, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(index.isMultiple(of: 4) ? Color.secondary.opacity(0.18) : Color.secondary.opacity(0.12))
                            .aspectRatio(1, contentMode: .fit)
                    }
                }
                .opacity(placeholderOpacity)
            }
            .scrollDisabled(true)
            .navigationTitle("Work in Progress")
            .background(Color(uiColor: .systemBackground))
            .overlay(alignment: .bottom) {
                if showsDelayedIndicator {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Still opening your library…")
                            .font(.subheadline)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Opening your photo library")
        .onAppear {
            withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) {
                placeholderOpacity = 0.8
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                showsDelayedIndicator = true
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private var backgroundUploadTask: UIBackgroundTaskIdentifier = .invalid
    private var didStartPersistenceServices = false
    private weak var application: UIApplication?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        self.application = application
        UNUserNotificationCenter.current().delegate = self
        guard !StorageTestConfiguration.isIsolatedHost else { return true }
        PortraitVideoExportService.shared.deleteTemporaryExports()
        PhotoUploadService.registerBackgroundTask()
        PhotoOfflineCoordinator.registerBackgroundTask()
        return true
    }

    func startPersistenceServices() {
        guard !StorageTestConfiguration.isIsolatedHost else { return }
        guard PersistenceController.shared.isLoaded, !didStartPersistenceServices else { return }
        didStartPersistenceServices = true
        _ = CloudSyncMonitor.shared
        DailyReminderNotificationService.shared.start(context: PersistenceController.shared.makeBackgroundContext())
        // UI fixtures must never recover or clean the simulator's normal originals.
        guard !StorageTestConfiguration.usesEphemeralLibrary else { return }

        #if DEBUG && targetEnvironment(simulator)
        // Keep normal-library upload journals, originals, and maintenance untouched.
        if SimulatorExampleLibrary.isEnabled {
            Task { await ICloudAvailabilityMonitor.shared.refresh() }
            return
        }
        #endif

        Task {
            do { try PhotoStorageCoordinator.shared.applyBackupPreference() }
            catch {
                PhotoStorageCoordinator.shared.recordStartupError(error)
                return
            }
            await ICloudAvailabilityMonitor.shared.refresh()
            let context = PersistenceController.shared.makeBackgroundContext()
            let recoveredCount = await PhotoStorageService.shared.recoverPendingUploadsFromManifest(context: context)
            if recoveredCount > 0 {
                let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "progress", category: "AppLifecycle")
                logger.log("pending-upload-manifest-recovered count=\(recoveredCount, privacy: .public)")
            }
            await PhotoStorageService.shared.recoverLegacyOriginals(context: context)
            await PhotoUploadService.shared.start()
            await RemoteAssetDeletionService.shared.start()
            PhotoOfflineCoordinator.shared.start()
            PhotoStorageCoordinator.shared.resume()
        }

        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(5))
            let context: NSManagedObjectContext? = await MainActor.run {
                guard PersistenceController.shared.isLoaded else { return nil }
                return PersistenceController.shared.makeBackgroundContext()
            }
            guard let context else { return }
            await PhotoStorageService.shared.optimizeStoredThumbnailsIfNeeded(context: context)
            await PhotoStorageService.shared.purgeOrphanedAssets(context: context)
        }
    }

    func handleEnteredBackground() {
        guard !StorageTestConfiguration.isIsolatedHost else { return }
        guard !StorageTestConfiguration.usesEphemeralLibrary else { return }
        #if DEBUG && targetEnvironment(simulator)
        if SimulatorExampleLibrary.isEnabled { return }
        #endif
        PhotoOfflineCoordinator.shared.scheduleBackgroundProcessing()
        guard let application else { return }
        Task {
            guard PersistenceController.shared.isLoaded else { return }
            guard ICloudAvailabilityMonitor.shared.isAvailableForCloudOperations else { return }
            PhotoUploadService.scheduleBackgroundProcessing()
            await MainActor.run {
                beginBackgroundUploadTaskIfNeeded(application)
            }
        }
    }

    func handleBecameActive() {
        guard !StorageTestConfiguration.isIsolatedHost else { return }
        DailyReminderNotificationService.shared.clearAllDeliveredNotifications()
        if didStartPersistenceServices {
            DailyReminderNotificationService.shared.refreshReminders()
        }
        guard !StorageTestConfiguration.usesEphemeralLibrary else { return }

        Task {
            guard PersistenceController.shared.isLoaded else { return }
            await ICloudAvailabilityMonitor.shared.refresh()
            #if DEBUG && targetEnvironment(simulator)
            if SimulatorExampleLibrary.isEnabled { return }
            #endif
            PhotoOfflineCoordinator.shared.requestReconciliation()
            PhotoStorageCoordinator.shared.resume()
            await PhotoUploadService.shared.enqueuePendingUploads(
                expeditingRetries: true,
                forceRetryExpedite: true
            )
            await RemoteAssetDeletionService.shared.processPendingDeletions(expeditingRetries: true)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        if await DailyReminderNotificationService.shared.shouldSuppressReminder(userInfo: notification.request.content.userInfo) {
            return []
        }
        return [.banner, .list, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        DailyReminderNotificationService.shared.clearAllDeliveredNotifications()

        let userInfo = response.notification.request.content.userInfo
        guard let timelineID = DailyReminderNotificationService.shared.timelineID(forReminder: userInfo) else {
            return
        }

        await MainActor.run {
            NotificationNavigationCoordinator.shared.requestCameraOpenFromNotification(timelineID: timelineID)
        }
    }

    private func beginBackgroundUploadTaskIfNeeded(_ application: UIApplication) {
        guard backgroundUploadTask == .invalid else { return }

        backgroundUploadTask = application.beginBackgroundTask(withName: "PhotoUpload") { [weak self] in
            Task { @MainActor in
                await PhotoUploadService.shared.cancelPendingWork()
                self?.endBackgroundUploadTask(application)
            }
        }

        Task { @MainActor in
            await PhotoUploadService.shared.processPendingUploadsDuringBackgroundTime()
            endBackgroundUploadTask(application)
        }
    }

    private func endBackgroundUploadTask(_ application: UIApplication) {
        guard backgroundUploadTask != .invalid else { return }

        application.endBackgroundTask(backgroundUploadTask)
        backgroundUploadTask = .invalid
    }
}
