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

    init() {
        loadRocketSimConnect()
    }

    var body: some Scene {
        WindowGroup {
            PersistenceRootView(persistenceController: persistenceController)
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    DailyReminderNotificationService.shared.clearAllDeliveredNotifications()
                }
                .task(id: persistenceController.loadState) {
                    guard persistenceController.isLoaded else { return }
                    appDelegate.startPersistenceServices()
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

private struct PersistenceRootView: View {
    @ObservedObject var persistenceController: PersistenceController

    var body: some View {
        switch persistenceController.loadState {
        case .loading:
            LibraryLoadingView()
        case .loaded:
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
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

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        PortraitVideoExportService.shared.deleteTemporaryExports()
        PhotoUploadService.registerBackgroundTask()
        return true
    }

    func startPersistenceServices() {
        guard PersistenceController.shared.isLoaded, !didStartPersistenceServices else { return }
        didStartPersistenceServices = true
        _ = CloudSyncMonitor.shared

        Task {
            await ICloudAvailabilityMonitor.shared.refresh()
            let context = PersistenceController.shared.makeBackgroundContext()
            let recoveredCount = await PhotoStorageService.shared.recoverPendingUploadsFromManifest(context: context)
            if recoveredCount > 0 {
                let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "progress", category: "AppLifecycle")
                logger.log("pending-upload-manifest-recovered count=\(recoveredCount, privacy: .public)")
            }
            await PhotoUploadService.shared.start()
            await RemoteAssetDeletionService.shared.start()
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

    func applicationDidEnterBackground(_ application: UIApplication) {
        Task {
            guard PersistenceController.shared.isLoaded else { return }
            guard ICloudAvailabilityMonitor.shared.isAvailableForCloudOperations else { return }
            PhotoUploadService.scheduleBackgroundProcessing()
            await MainActor.run {
                beginBackgroundUploadTaskIfNeeded(application)
            }
        }
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        DailyReminderNotificationService.shared.clearAllDeliveredNotifications()

        Task {
            guard PersistenceController.shared.isLoaded else { return }
            await ICloudAvailabilityMonitor.shared.refresh()
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
        [.banner, .list, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        center.removeAllDeliveredNotifications()

        let userInfo = response.notification.request.content.userInfo
        guard DailyReminderNotificationService.shared.isDailyReminderNotification(userInfo: userInfo) else {
            return
        }

        await MainActor.run {
            NotificationNavigationCoordinator.shared.requestCameraOpenFromNotification()
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
