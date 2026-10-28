import AVFoundation

nonisolated enum CameraPosition: String, CaseIterable, Sendable {
    case front
    case back

    var opposite: Self { self == .front ? .back : .front }

    var captureDevicePosition: AVCaptureDevice.Position {
        self == .front ? .front : .back
    }

    // Select the physical main lens, avoiding virtual multi-camera lens switching.
    var captureDeviceType: AVCaptureDevice.DeviceType { .builtInWideAngleCamera }
}
