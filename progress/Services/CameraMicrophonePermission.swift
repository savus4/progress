import AVFoundation

/// Keep microphone permission optional and separate from camera access.
enum CameraMicrophonePermission {
    static func authorize(
        enabled: Bool,
        status: () -> AVAuthorizationStatus,
        request: () async -> Bool
    ) async -> Bool {
        guard enabled, !Task.isCancelled else { return false }
        switch status() {
        case .authorized:
            return true
        case .notDetermined:
            return await request()
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}
