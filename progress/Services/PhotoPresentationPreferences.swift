import Foundation

@MainActor
enum PhotoPresentationPreferences {
    /// Device-local presentation preference; never written to photo records.
    static var mirrorsPhotos: Bool {
        UserDefaults.standard.bool(forKey: CameraPreferenceKey.hirsModeProEnabled)
    }
}
