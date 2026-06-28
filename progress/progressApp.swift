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

    let persistenceController = PersistenceController.shared

    init() {
        Task { @MainActor in
            _ = CloudSyncMonitor.shared
        }
        loadRocketSimConnect()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    DailyReminderNotificationService.shared.clearAllDeliveredNotifications()
                }
        }
    }

    private func loadRocketSimConnect() {
        #if DEBUG
        guard (Bundle(path: "/Applications/RocketSim.app/Contents/Frameworks/RocketSimConnectLinker.nocache.framework")?.load() == true) else {
            print("Failed to load linker framework")
            return
        }
        print("RocketSim Connect successfully linked")
        #endif
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private var backgroundUploadTask: UIBackgroundTaskIdentifier = .invalid

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        PortraitVideoExportService.shared.deleteTemporaryExports()
        PhotoUploadService.registerBackgroundTask()

        Task {
            await ICloudAvailabilityMonitor.shared.refresh()
            let context = await MainActor.run {
                PersistenceController.shared.makeBackgroundContext()
            }
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
            let context = await MainActor.run {
                PersistenceController.shared.makeBackgroundContext()
            }
            await PhotoStorageService.shared.optimizeStoredThumbnailsIfNeeded(context: context)
            await PhotoStorageService.shared.purgeOrphanedAssets(context: context)
        }
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        Task {
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
