import Foundation

enum CameraPreferenceKey {
    // Legacy device-wide setting, read only when migrating Default.
    static let livePhotoCaptureEnabled = "experimentalCameraLivePhotoCaptureEnabled"
    static let hirsModeEnabled = "cameraHirsModeEnabled"
}
