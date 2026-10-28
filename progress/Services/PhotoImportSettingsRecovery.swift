import Foundation

/// Photos permission changes can terminate the app while Settings is open.
enum PhotoImportSettingsRecovery {
    private static let key = "photoImportSettingsRecovery"
    private static let lifetime: TimeInterval = 30 * 60

    static func save(_ request: PhotoImportResumeRequest, defaults: UserDefaults = .standard) {
        guard request.method.requiresFullAccess else { return }
        defaults.set(try? JSONEncoder().encode(request), forKey: key)
    }

    static func consume(defaults: UserDefaults = .standard, now: Date = Date()) -> PhotoImportResumeRequest? {
        defer { clear(defaults: defaults) }
        guard let data = defaults.data(forKey: key),
              let request = try? JSONDecoder().decode(PhotoImportResumeRequest.self, from: data),
              request.method.requiresFullAccess,
              (0...lifetime).contains(now.timeIntervalSince(request.createdAt)) else { return nil }
        return request
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}
