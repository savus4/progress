import Darwin
import Foundation
import UIKit

enum SupportEmail {
    static let recipient = "wip-support@riepl.me"

    static func makeURL() -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = recipient
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Work in Progress — Support"),
            URLQueryItem(name: "body", value: messageBody.replacingOccurrences(of: "\n", with: "\r\n"))
        ]
        // Preserve literal plus signs in mail clients that also decode form-style queries.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    private static var messageBody: String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        let device = UIDevice.current
        let sync = CloudSyncMonitor.shared
        let storage = PhotoStorageCoordinator.shared
        let defaults = UserDefaults.standard

        #if DEBUG
        let configuration = "Debug"
        #else
        let configuration = "Release"
        #endif

        #if targetEnvironment(simulator)
        let environment = "Simulator"
        #else
        let environment = "Device"
        #endif

        return """
        Hi Simon,

        I need help with Work in Progress.

        What happened:


        What I expected:


        --- App & device details ---
        App: Work in Progress \(version) (\(build))
        Build: \(configuration), \(environment)
        Device: \(device.model) (\(deviceModelIdentifier))
        System: \(device.systemName) \(device.systemVersion)
        Language: \(Locale.preferredLanguages.first ?? "Unknown")
        Locale: \(Locale.current.identifier)
        Time zone: \(TimeZone.current.identifier)
        Low Power Mode: \(ProcessInfo.processInfo.isLowPowerModeEnabled)
        Photo storage: \(storage.mode.rawValue)
        Sync: \(sync.statusTitle)
        Sync details: \(sync.statusDetail)
        Last completed sync: \(sync.lastSyncDate?.ISO8601Format() ?? "None")
        Uploads: \(sync.pendingUploadCount) pending, \(sync.uploadingAssetCount) active, \(sync.failedUploadCount) failed, \(sync.pausedUploadCount) paused
        Downloads: \(sync.downloadingAssetCount) active
        Hirs-Mode: \(defaults.bool(forKey: CameraPreferenceKey.hirsModeEnabled))
        Hirs-Mode Pro: \(defaults.bool(forKey: CameraPreferenceKey.hirsModeProEnabled))
        """
    }

    private static var deviceModelIdentifier: String {
        #if targetEnvironment(simulator)
        if let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return model
        }
        #endif

        var systemInfo = utsname()
        guard uname(&systemInfo) == 0 else { return "Unknown" }
        return withUnsafeBytes(of: &systemInfo.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
